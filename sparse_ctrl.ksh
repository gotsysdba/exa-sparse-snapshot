#!/bin/env ksh
# Source the sharedlib
source ./sharedlib

#------------------------------------------------------------------------------
# GLOBAL/DEFAULT VARS
#------------------------------------------------------------------------------
typeset -rx SCRIPT_NAME="${0##*/}"
typeset -r  DEFAULT_DIR="${HOME}/SPARSE_CLONE"

#------------------------------------------------------------------------------
# LOCAL FUNCTIONS
#------------------------------------------------------------------------------
function usage {
	# Required Usage Function
	print -- "${SCRIPT_NAME} Usage"
	print -- "\t\t${SCRIPT_NAME} -a <CONVERT|CLONE|DROP|REVERT> -b <Test Master> [-c <CloneDB>]"
	print -- ""
	print -- "\t\t${SCRIPT_NAME} -a CONVERT -b <Test Master> : Convert a Physical Standby to the TestMaster"
	print -- "\t\t${SCRIPT_NAME} -a CLONE -b <Test Master> -c <CloneDB> : Create a Sparse Clone of the TestMaster"
	print -- "\t\t${SCRIPT_NAME} -a DROP -b <Test Master> -c <CloneDB> : Remove a Sparse Clone of the TestMaster"
	print -- "\t\t${SCRIPT_NAME} -a REVERT -b <Test Master> : Revert the TestMaster back to a Physical Standby"
	return 0
}

function get_sparse_dg {
	typeset -n _SPARSE=$1
	typeset -i _RC=0

	e_print "INFO" "Running ${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba lsattr -ml cell.sparse_dg"
	${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba lsattr -ml cell.sparse_dg |while read _DG _ATTR _VAL _THROWAWAY; do
        if [[ ${_VAL} != "allsparse" ]]; then
            continue
        fi
		e_print "INFO" "Found Sparse Diskgroup: ${_DG}"
        _SPARSE="${_DG}:${_SPARSE}"
	done

	return ${_RC}
}

function clean_asm {
	typeset -r _DIRNAME=$1

	${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba lsdg | awk '{print $NF}' | while read _ASMDG; do
		if [[ ${_ASMDG} == "Name" ]]; then
			continue
		fi
        ${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba ls ${_ASMDG}/${_DIRNAME} | while read _ASMDIR; do
            e_print "INFO" "Removing ${_ASMDG}${_DIRNAME}/${_ASMDIR}"
            ${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba rm -rf ${_ASMDG}${_DIRNAME}/${_ASMDIR}
        done
		${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba rm -rf ${_ASMDG}${_DIRNAME}
    done
}

function create_pfile {
	typeset -r _PFILE=$1
	typeset -r _CONTROL=$2
	typeset -r _CLONE=$3
	typeset -r _PRIMARY=$4
	typeset -r _WALLET=$5
	typeset -r _RC=0

	cat <<- EOF > ${_PFILE}
		_no_recovery_through_resetlogs=TRUE
		control_files='${_CONTROL}'
		audit_trail=DB
		db_name=${_PRIMARY}
		db_unique_name=${_CLONE}
		sga_target=5g
		enable_pluggable_database=true
		tde_configuration='keystore_configuration=FILE'
		wallet_root='${_WALLET}'
	EOF

	if [[ ! -f ${_PFILE} ]]; then
		e_fatal "Unable to create ${_PFILE}"
	fi
	e_print "INFO" "Created ${_PFILE}"

	return ${_RC}
}

#------------------------------------------------------------------------------
# INIT
#------------------------------------------------------------------------------
while getopts :a:b:c:h args; do
	case $args in
		a) typeset -ru MYACTION="$OPTARG" ;;
		b) typeset -ru MYTESTMASTER="$OPTARG" ;;
		c) typeset -ru MYCLONE="$OPTARG" ;;
		h) usage ;;
	esac
done
shift $((OPTIND-1));

if [[ -z ${MYTESTMASTER} || -z ${MYACTION} ]]; then
	usage && e_fatal "Not all required options given"
fi

if [[ ${MYACTION} != @(CONVERT|CLONE|DROP|REVERT) ]]; then
	usage && e_fatal "Invalid Action"
fi

if [[ ! -r /etc/oracle/olr.loc ]]; then
	e_fatal "Unable to find the GI Home"
fi

e_get_crs_home "CRS_HOME"
e_exp_crs_configs "${CRS_HOME}" "${MYTESTMASTER}"
export ORACLE_HOME=${CRS_ORACLE_HOME}
export ORACLE_SID=${CRS_USR_ORA_INST_NAME}
export DB_UNIQUE_NAME=${CRS_DB_UNIQUE_NAME}
export DB_NAME=${CRS_USR_ORA_DB_NAME}

# Create a directory to store files
if [[ -z ${MYSPARSE_DIR} ]]; then
    typeset -r SPARSE_DIR=${DEFAULT_DIR}
else
    typeset -r SPARSE_DIR=${MYSPARSE_DIR}
fi
typeset -r TM_DIR=${SPARSE_DIR}/${DB_UNIQUE_NAME}
mkdir -p ${TM_DIR}
e_print "INFO" "Storing TestMaster files in ${TM_DIR}"
if [[ -n ${MYCLONE} ]]; then
	typeset -r SN_DIR=${TM_DIR}/${MYCLONE}
	mkdir -p ${SN_DIR}
fi

#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------
# Find/Verfify SPARSE DG
typeset SPARSE_DG
get_sparse_dg "SPARSE_DG"
if [[ ! -n ${SPARSE_DG} ]]; then
	e_fatal "Unable to find a Sparse Diskgroup"
fi
# If user specified the sparse DG, verify it is Sparse and use 
if [[ -n ${MYDSTDG} ]] && [[ ${SPARSE_DG//${MYDSTDG}} == ${SPARSE_DG} ]]; then
	e_fatal "Specified Sparse DG: ${MYDSTDG} is not sparse or does not exist; exiting..."
elif [[ -n ${MYDSTDG} ]]; then
	typeset -r DSTDG="+${MYDSTDG#+}"
fi
# No user specified DG, use the first DG found
if [[ -z ${DSTDG} ]]; then

	SPARSE_DG=${SPARSE_DG%:*}
	typeset -r DSTDG="+${SPARSE_DG#+}"
fi
e_print "INFO" "Using Sparse Diskgroup: ${DSTDG}"

# Set File Variables used in different Stages
typeset -r TM_RENAME_SQL="${TM_DIR}/tm_df_rename.sql"
typeset -r TM_MKDIR_SH="${TM_DIR}/asm_mkdir.sh"
typeset -r TM_RW_SQL="${TM_DIR}/tm_rw.sql"

if [[ ${MYACTION} == "CONVERT" ]]; then
	e_print "INFO" "############################################################"
	e_print "INFO" "# Deferring Redo Transport"
	e_print "INFO" "############################################################"
    e_run_dgmgrl "DGMGRL_OUT" "/ as sysdba" "show configuration"
	if (( $? > 0 )); then
		e_fatal "Unable to defer redo transport; exiting"
	fi
    e_run_dgmgrl "DGMGRL_OUT" "/ as sysdba" "edit database '${DB_UNIQUE_NAME}' set property logshipping=OFF;"
    e_run_dgmgrl "DGMGRL_OUT" "/ as sysdba" "edit database '${DB_UNIQUE_NAME}' set state=APPLY-OFF;"

	e_print "INFO" "############################################################"
	e_print "INFO" "# Preparing Files to use Standby as the TestMaster"
	e_print "INFO" "############################################################"
	# Create PFILE
	typeset -r TM_PFILE="${TM_DIR}/tmorig_pfile.ora" 
	e_run_sql "CREATE PFILE='${TM_PFILE}' from SPFILE;"
	# Determine current db_create_file_dest
	if [[ ! -f ${TM_PFILE} ]]; then
		fatal "Failed to create pfile ${TM_PFILE}"
	fi

	# Get the Diskgroup for the Full Datafiles
	TM_SRCDG=$(grep "db_create_file_dest=" ${TM_PFILE} |awk -F\' '{print $2}')
	if [[ -z ${TM_SRCDG} ]]; then
		e_fatal "Failed to determine the db_create_file_dest"
	fi
	e_print "INFO" "Source Diskgroup: ${TM_SRCDG}"

	# Get the Wallet Location
	typeset -r TM_WALLET_DIR=$(grep wallet_root ${TM_PFILE} | awk -F= '{print $2}')

	e_get_sql_output "TRC_LOC" "SELECT value FROM v\$diag_info WHERE name = 'Default Trace File';"
	e_print "INFO" "Generating Controlfile Trace to: ${TRC_LOC%/*}"

	# Generate Controlfile to Trace
	typeset -r TRC_SQL="ALTER SESSION SET TRACEFILE_IDENTIFIER='CNTRL_TRC';
			   ALTER DATABASE BACKUP CONTROLFILE TO TRACE;"
	e_run_sql "${TRC_SQL}"

	typeset -r CTRL_TRC=$(ls -tr ${TRC_LOC%/*}/*CNTRL_TRC.trc |tail -1)
	if [[ ! -f ${CTRL_TRC} ]]; then
		e_fatal "Unable to find Controlfile Trace: ${TRC_LOC%/*}/*CNTRL_TRC.trc"
	fi

	e_print "INFO" "ControlFile Trace Generated: ${CTRL_TRC}"

	awk '/CREATE CONTROLFILE REUSE DATABASE .* RESETLOGS FORCE LOGGING ARCHIVELOG/,/;/' \
		${CTRL_TRC} > ${TM_DIR}/tmorig_control.trc
	e_print "INFO" "Modified trace to ${TM_DIR}/tmorig_control.trc"

	# Generate DB Rename Script
	typeset -r RENAME_SQL="select 'EXECUTE dbms_dnfs.clonedb_renamefile ('||''''||d.name||''''||
	                        ','||''''||replace(d.name, '${TM_SRCDG}/','${DSTDG}/')||'_${NOW}'''||
	                        ');' from v\$datafile d, v\$containers c 
                            where d.con_id = c.con_id and c.name <> 'PDB\$SEED';"
	e_run_sql "${RENAME_SQL}" "${TM_RENAME_SQL}"

	# Generate ASM MKDIR Script (note in mount, so no with cluase)
	typeset -r MKDIR_SQL="
		SELECT '${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba mkdir '||d.dir||CHR(13)||CHR(10)
		  from 
			(select replace(dir_path,'${TM_SRCDG}/','${DSTDG}/') dir
				from (select distinct dir_level, substr(name,1,regexp_instr(name,'/',1,dir_level)-1) dir_path
						from v\$datafile, 
							(select level dir_level 
								from dual connect by level <= (select max(regexp_count(name,'/')) from v\$datafile))
								where dir_level > 1)
						where dir_path is not null order by dir_level) d;"
	e_run_sql "${MKDIR_SQL}" "${TM_MKDIR_SH}"
	print -- "${CRS_HOME}/bin/asmcmd --nocp --privilege sysdba find ${DSTDG}/${DB_UNIQUE_NAME} DATAFILE" >> ${TM_MKDIR_SH}

	# Generate Script to change datafile to RW after dbfs_clone
	typeset -r RW_SQL="select 'ALTER DISKGROUP ${TM_SRCDG#+} set permission owner=read write, 
		group=read write, other=none for file '||''''||name||''''||';' from v\$datafile;"
	e_run_sql "${RW_SQL}" "${TM_RW_SQL}"

    e_print "INFO" "############################################################"
    e_print "INFO" "# Shutting Down Testmaster ${DB_UNIQUE_NAME}"
    e_print "INFO" "############################################################"
	${ORACLE_HOME}/bin/srvctl stop database -db ${DB_UNIQUE_NAME}
fi

if [[ ${MYACTION} == "REVERT" ]]; then
    e_print "INFO" "############################################################"
    e_print "INFO" "# Dropping Clones associated with ${DB_UNIQUE_NAME}"
    e_print "INFO" "############################################################"
	for CLONE in $(find ${TM_DIR} -type f -name pfile*.ora ); do
		export ORACLE_SID=$(awk -F/ '{print $(NF-1)}' <<< ${CLONE})	
		e_print "INFO" "Dropping Clone ${ORACLE_SID}"
		$ORACLE_HOME/bin/rman <<- EOF
       		connect target /
			startup force mount pfile='${CLONE}'
			ALTER SYSTEM ENABLE RESTRICTED SESSION;
			DROP DATABASE INCLUDING BACKUPS NOPROMPT;
		EOF
	
		# Clean ASM
		clean_asm "${ORACLE_SID}"
		e_print "INFO" "Removing ${CLONE%\/*}"
		rm -rf ${CLONE%\/*}
	done

	export ORACLE_SID=${CRS_USR_ORA_INST_NAME}
    e_print "INFO" "############################################################"
    e_print "INFO" "# Starting up Testmaster ${DB_UNIQUE_NAME} (${ORACLE_SID})"
    e_print "INFO" "############################################################"
	${ORACLE_HOME}/bin/srvctl start database -db ${DB_UNIQUE_NAME}
	e_run_sql "@${TM_RW_SQL}"

    e_print "INFO" "############################################################"
    e_print "INFO" "# Resuming Redo Transport"
    e_print "INFO" "############################################################"
	e_run_dgmgrl "DGMGRL_OUT" "/ as sysdba" "edit database '${DB_UNIQUE_NAME}' set state=APPLY-ON;"
    e_run_dgmgrl "DGMGRL_OUT" "/ as sysdba" "edit database '${DB_UNIQUE_NAME}' set property logshipping=ON;"
	e_run_dgmgrl "DGMGRL_OUT" "/ as sysdba" "show configuration"

	rm -rf ${TM_DIR}
fi

if [[ ${MYACTION} == "CLONE" ]]; then
    e_print "INFO" "############################################################"
    e_print "INFO" "# Preparing Files for Clone"
    e_print "INFO" "############################################################"
	# Create a pfile for the Clone
	typeset -r SN_PFILE="${SN_DIR}/pfile_${MYCLONE}.ora"
	typeset -r SN_CTRL="${DSTDG}/${MYCLONE}/CONTROLFILE/control1.f"
	create_pfile "${SN_PFILE}" "${SN_CTRL}" "${MYCLONE}" "${DB_NAME}" "${TM_WALLET_DIR}"

	# Create controlfile.sql for the Clone
	typeset -r SN_CTRL_SQL="${SN_DIR}/control.sql"
	sed "s|${DB_UNIQUE_NAME}/ONLINELOG|${MYCLONE}/ONLINELOG|g" ${TM_DIR}/tmorig_control.trc > ${SN_CTRL_SQL}
	e_print "INFO" "Created ${SN_CTRL_SQL}"

	# Create Rename File for the Clone
	typeset -r SN_RENAME_SQL="${SN_DIR}/df_rename.sql"
	sed "s|${DSTDG}/${DB_UNIQUE_NAME}|${DSTDG}/${MYCLONE}|g" ${TM_RENAME_SQL} > ${SN_RENAME_SQL}
	e_print "INFO" "Created ${SN_RENAME_SQL}"

	# Create ASM mkdir for the Clone
	typeset -r SN_MKDIR_SH="${SN_DIR}/asm_mkdir.sh"
	sed "s|${DB_UNIQUE_NAME}|${MYCLONE}|g" ${TM_MKDIR_SH} > ${SN_MKDIR_SH}
	e_print "INFO" "Created ${SN_MKDIR_SH}"

	e_print "INFO" "Running ${SN_MKDIR_SH}"
	sh ${SN_MKDIR_SH} |while read MKDIR_OUT; do
		e_print "ASMCMD" "${MKDIR_OUT}"
	done

	export ORACLE_SID=${MYCLONE}
	e_run_sql "startup nomount pfile=${SN_PFILE}"
	e_run_sql "@${SN_CTRL_SQL}"
	e_run_sql "@${SN_RENAME_SQL}"
	e_run_sql "ALTER DATABASE OPEN RESETLOGS;"
	#e_run_sql "SELECT filenumber num, clonefilename child, snapshotfilename parent FROM V\$CLONEDFILE;"
fi

if [[ ${MYACTION} == "DROP" ]]; then
    e_print "INFO" "############################################################"
    e_print "INFO" "# Dropping ${MYCLONE} Clone associated with ${DB_UNIQUE_NAME}"
    e_print "INFO" "############################################################"
	export ORACLE_SID=${MYCLONE}
	e_print "INFO" "Dropping Clone ${ORACLE_SID}"
	typeset -r SN_PFILE="${SN_DIR}/pfile_${ORACLE_SID}.ora"
	if [[ -f ${SN_PFILE} ]]; then
		$ORACLE_HOME/bin/rman <<- EOF
			connect target /
			startup force mount pfile='${SN_PFILE}'
			ALTER SYSTEM ENABLE RESTRICTED SESSION;
			DROP DATABASE INCLUDING BACKUPS NOPROMPT;
		EOF
	fi
	# Clean ASM
	clean_asm "${ORACLE_SID}"
	e_print "INFO" "Removing ${SN_DIR}"
	rm -rf ${SN_DIR}
fi