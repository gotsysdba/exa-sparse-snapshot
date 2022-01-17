#!/bin/env ksh
# Source the sharedlib
source ./sharedlib

#------------------------------------------------------------------------------
# GLOBAL/DEFAULT VARS
#------------------------------------------------------------------------------
# Setup for Success
typeset -i RC=0
# Prevent Profile violations by stamping pwd
typeset -r BOOT_PASS="Dupl_5y5B4CkUP_$(date +%d%H%M%S)"
typeset -r DG_USER="SYSDG"
typeset -r DG_ROLE="SYSDG"
typeset -r DG_CONFIG_NAME="dg_sparse"

#------------------------------------------------------------------------------
# LOCAL FUNCTIONS
#------------------------------------------------------------------------------
function run_srvctl {
	typeset -r _CMD=$1
	typeset -i _RC=0

	e_print "INFO" "Running - $ORACLE_HOME/bin/srvctl ${_CMD}"
	$ORACLE_HOME/bin/srvctl ${_CMD} | while read _SRVCTL_OUT; do
		e_print "INFO" "${_SRVCTL_OUT}"
	done
	_RC=$?

	return ${_RC}
}

function dupl_lsnr {
	typeset -ru _ACTION=$1
	typeset -r  _LISTENER=$2
	typeset -i  _PORT=$3
	typeset -r  _GLOBAL_NAME=$4
	typeset -r  _STANDBY=$5
	typeset -i  _RC=0

	e_print "INFO" "Removing Listener ${_LISTENER} used for Duplicating"
	run_srvctl "stop listener -l ${_LISTENER}"
	run_srvctl "remove listener -l ${_LISTENER}"
	sed -i /"#--- Temporary ${_LISTENER} Registration Start ---"/,/"#--- Temporary ${_LISTENER} Registration End ---"/d ${ORACLE_HOME}/network/admin/listener.ora

	if [[ ${_ACTION} == "ADD" ]]; then
		e_print "INFO" "Creating Listener ${_LISTENER} used for Duplicating"
		run_srvctl "add listener -l ${_LISTENER} -p TCP:${_PORT} -o $ORACLE_HOME"
		cat <<- EOF >> ${ORACLE_HOME}/network/admin/listener.ora
			#--- Temporary ${_LISTENER} Registration Start ---
			SID_LIST_${_LISTENER}=(SID_LIST=(SID_DESC=(GLOBAL_DBNAME=${_GLOBAL_NAME})(ORACLE_HOME=${ORACLE_HOME})(SID_NAME=${_STANDBY}))) 
			#--- Temporary ${_LISTENER} Registration End ---
		EOF
		run_srvctl "start listener -l ${_LISTENER}"
	fi

	return ${_RC}
}

function boot_pwd {
	typeset -r _PRIMARY=$1
	typeset -r _STANDBY=$2
	typeset -r _PWD_FILE=$3
	typeset -i _RC=0

	e_print "INFO" "Bootstrapping SYS/${DG_USER} Users Password for Duplicating/DataGuard"
	$ORACLE_HOME/bin/sqlplus /nolog <<- EOF > /dev/null
		connect / as SYSDBA
		whenever sqlerror exit 1
		set echo on
		alter user SYS identified by ${BOOT_PASS};
		alter user ${DG_USER} account unlock identified by ${BOOT_PASS};
		grant ${DG_ROLE} to ${DG_USER};
	EOF
	_RC=$?

	# Copy the PRIMARY password file to the Standby
	orapwd file=$ORACLE_HOME/dbs/orapw${_STANDBY} input_file=${_PWD_FILE} force=Y
	return ${_RC}
}

function manage_srl {
	typeset -r _PRIMARY=$1
	typeset -i _RC=0

	if [[ ! -f ./manage_srl.sql ]]; then
		e_fatal "Unable to find manage_srl.sql script"
	fi

	e_print "INFO" "Managing Standby Redo Logs"
	$ORACLE_HOME/bin/sqlplus /nolog <<- EOF 
		connect / as SYSDBA
		@./manage_srl.sql
	EOF
	_RC=$?

	return ${_RC}
}

function stdby_pfile {
	typeset -r _PRIMARY=$1
	typeset -r _STANDBY=$2
	typeset -r _PFILE=$3
	typeset -i _RC=0

	e_print "INFO" "Creating ${_PFILE}.ora from ${_PRIMARY}"
	if [[ -f ${_PFILE} ]]; then
		rm -f ${_PFILE}
	fi

	$ORACLE_HOME/bin/sqlplus -s /nolog <<- EOF > /dev/null
		connect / as SYSDBA
		whenever sqlerror exit 1
		SET ECHO OFF VERIFY OFF FEEDBACK OFF TERMOUT OFF TRIMSPOOL ON PAGES 0 LINES 4000 TIMING OFF
		col entry format a4000 word_wrapped
		spool ${_PFILE}
		select '*.'||name||'='||regexp_replace(value,'${_PRIMARY%%.*}','${_STANDBY%%.*}') entry
		  from v\$parameter
			 where value is not null and ISDEFAULT='FALSE'
		  and name NOT in ( 'control_files','cluster_database','dispatchers'
				   ,'remote_listener','local_listener','db_name'
				   ,'log_archive_config','dg_broker_start','dg_broker_config_file2','dg_broker_config_file1'
				   ,'thread','instance_number');
	EOF
	_RC=$?

	if (( ${_RC} == 0 )) && [[ -f ${_PFILE} ]]; then
		e_print "INFO" "Successfully Created pfile: ${_PFILE}"
		# Quote Strings
		sed -i s/"LOCATION=.*"/"\'&\'"/g ${_PFILE}
		sed -i s/"keystore_configuration=.*"/"\'&\'"/g ${_PFILE}
		# Add Unique Values
		print "*.db_name=${_PRIMARY%%.*}" >> ${_PFILE}
		print "*.dg_broker_start=TRUE" >> ${_PFILE}
		print "*.cluster_database=FALSE" >> ${_PFILE}
		print "*.STANDBY_FILE_MANAGEMENT=AUTO" >> ${_PFILE}
	else
		e_print "ERROR" "Failed to Create pfile"
	fi	
}

function dupl_db {
	typeset -n _SPFILE=$1
	typeset -r _PRIMARY=$2
	typeset -r _PRIMARY_EZ=$3
	typeset -r _STANDBY=$4
	typeset -r _STANDBY_EZ=$5
	typeset -r _PFILE=$6
	typeset -r _DOMAIN=$7
	typeset -i _RC=0

	# Get the wallet_root location and copy from Prod
	typeset -r _WALLET_DIR=$(grep wallet_root ${_PFILE} | awk -F= '{print $2}')
	if [[ -n ${_WALLET_DIR} ]]; then
		e_print "INFO" "Copying ${_WALLET_DIR/${_STANDBY}/${_PRIMARY}}/* to ${_WALLET_DIR}"
		# This should be an ACFS directory
		mkdir -p ${_WALLET_DIR}
		cp -rp ${_WALLET_DIR/${_STANDBY}/${_PRIMARY}}/* ${_WALLET_DIR}
	else
		e_fatal "Unable to determine wallet directory"
		exit 1
	fi

	# Get the db_create_file_dest for SPFILE creation
	typeset -ru _SPFILE_DIR=$(grep db_create_file_dest ${_PFILE} | awk -F= '{print $2}')
	typeset -ru _DB_UNIQUE=$(grep db_unique_name ${_PFILE} | awk -F= '{print $2}')
	typeset -r  _SPFILE="${_SPFILE_DIR}/${_DB_UNIQUE}/PARAMETERFILE/spfile${_STANDBY}.ora"
	echo "SPFILE=${_SPFILE}" > ${ORACLE_HOME}/dbs/init${_STANDBY}.ora

	export ORACLE_SID=${_STANDBY}
	e_print "INFO" "Set ORACLE_SID=${ORACLE_SID}"

	# The stop/remove is done to make script re-runnable.  CRS entry may not exist at this point
	run_srvctl "stop database -d ${_DB_UNIQUE} -o abort -f"
	run_srvctl "remove database -d ${_DB_UNIQUE} -f"

	e_print "INFO" "Starting ${_STANDBY} in NOMOUNT with ${_SPFILE}"
	# Start, SPFILE, Start Force so that ASM directories exist
	$ORACLE_HOME/bin/sqlplus /nolog <<- EOF
		connect / as SYSDBA
		shutdown abort
		startup pfile=${_PFILE} nomount;
		create spfile='${_SPFILE}' from pfile='${_PFILE}';
		startup force nomount;
	EOF

	e_print "INFO" "Connecting to Primary (target):    SYS/${BOOT_PASS}@${_PRIMARY_EZ} AS SYSDBA"
	e_print "INFO" "Connecting to Standby (auxiliary): SYS/${BOOT_PASS}@${_STANDBY_EZ} AS SYSDBA"

	$ORACLE_HOME/bin/rman <<- EOF
		connect target "SYS/${BOOT_PASS}@${_PRIMARY_EZ} AS SYSDBA";
		connect auxiliary "SYS/${BOOT_PASS}@${_STANDBY_EZ} AS SYSDBA";
		run {
			allocate channel c1 type disk;
			allocate auxiliary channel aux type disk;
			duplicate target database for standby from active database nofilenamecheck;
		}
	EOF
	_RC=$?
	e_print "INFO" "RMAN Returned with Exit Status: ${_RC}"

	if (( ${_RC} != 0 )); then
		e_print "ERROR" "Duplicate Failed; Dropping"
		$ORACLE_HOME/bin/rman <<- EOF
			connect target /
			startup force mount;
			alter system enable restricted session;
			drop database including backups noprompt;
		EOF
	else 
		$ORACLE_HOME/bin/sqlplus /nolog <<- EOF
			connect / as SYSDBA
			shutdown immediate
		EOF
		# Add the database into CRS (leaving this as a SI) and start nomount
	
		run_srvctl "add database -d ${_DB_UNIQUE} -n ${_PRIMARY} -i ${_STANDBY} -m ${_DOMAIN} -o ${ORACLE_HOME} -c SINGLE -x $(hostname)"
		run_srvctl "modify database -d ${_DB_UNIQUE} -r  physical_standby -s MOUNT -p ${_SPFILE} -a ${_SPFILE_DIR/+/}"
		run_srvctl "start database -db ${_DB_UNIQUE}"
	fi

	return ${_RC}	
}

function dgmgrl_config {
	typeset -r _CONFIG_NAME=$1
	typeset -r _DBNAME=$2
	typeset -r _CONN_STR=$3
	typeset -r _TYPE=$4
	typeset -i _RC=0

	typeset _DGMGRL_OUT
	typeset -r _AUTHN="${DG_USER}/${BOOT_PASS} AS ${DG_ROLE}"
	if [[ ${_TYPE} == "PRIMARY" ]]; then
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "sql \"alter system set dg_broker_start=FALSE scope=both sid='*'\";"
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "sql \"alter system set dg_broker_config_file1='+DATAC1/${_DBNAME}/PARAMETERFILE/DG1.DAT' scope=both sid='*'\";"
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "sql \"alter system set dg_broker_config_file1='+DATAC1/${_DBNAME}/PARAMETERFILE/DG2.DAT' scope=both sid='*'\";"
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "sql \"alter system set dg_broker_start=TRUE scope=both sid='*'\";"
		sleep 60 # Allow the broker to startup
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "create configuration '${_CONFIG_NAME}' as primary database is '${_DBNAME%%.*}' connect identifier is \"${_CONN_STR}\";"
		case ${_DGMGRL_OUT} in
			*Configuration*created* ) e_print "INFO" "Success"; _RC=0 ;;
			*ORA-16613*) _RC=1 ;; # initialization in progress for database
			*ORA-16504*) _RC=0 ;; # The Oracle Data Guard configuration already exists.
			* ) _RC=1 ;;
		esac

		if (( ${_RC} == 0 )); then
			e_print "INFO" "dgmgrl configuration succeeded"
			e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "edit configuration set protection mode as maxperformance;"
			e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "enable configuration;"
		else
			e_print "ERROR" "dgmgrl configuration failed"
			e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "sql \"alter system set dg_broker_start=FALSE scope=both sid='*'\";"
			return ${_RC}
		fi
	elif [[ ${_TYPE} == "STANDBY" ]]; then
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "add database '${_DBNAME%%.*}' as connect identifier is \"${_CONN_STR}\";"
		case ${_DGMGRL_OUT} in
			*added*	) _RC=0 ;;
			ORA-16698* ) _RC=0 ;; #LOG_ARCHIVE_DEST_n parameter set for object to be added
			* ) _RC=1
		esac
	fi
	e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "edit database '${_DBNAME%%.*}' set property logxptmode=ASYNC;"
	e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "edit database '${_DBNAME%%.*}' set property DbDisplayName='${_DBNAME}';"
	e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "enable database '${_DBNAME%%.*}';"
	e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "show configuration"
	_RC=$?
	if [[ ${_TYPE} == "STANDBY" ]] && (( ${_RC} == 0 )); then
		# Must be run after the enable
		# DO a stop first to avoid ORA-16826: apply service state is inconsistent with the DelayMins property 
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "edit database '${_DBNAME%%.*}' set state='APPLY-OFF';"
		e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "edit database '${_DBNAME%%.*}' set state='APPLY-ON';"
	fi

	return ${_RETCODE}
}

function dgmgrl_remove {
    typeset -r _CONFIG_NAME=$1
	typeset -r _DBNAME=$2
    typeset -i _RC=0

	typeset -r _AUTHN="${DG_USER}/${BOOT_PASS} AS ${DG_ROLE}"
	e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "remove database '${_DBNAME}';"
	e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "disable CONFIGURATION ${_CONFIG_NAME};"
	e_run_dgmgrl "_DGMGRL_OUT" "${_AUTHN}" "remove CONFIGURATION ${_CONFIG_NAME};"

	return ${_RC}
}


#------------------------------------------------------------------------------
# INIT
#------------------------------------------------------------------------------
typeset -r PRIMARY=$1
typeset -r STANDBY=$2

if [[ -z ${PRIMARY} ]] || [[ -z ${STANDBY} ]]; then 
	e_fatal "Must provide a Primary/Standby Database Name"
fi

if [[ ! -f ${HOME}/${PRIMARY}.env ]]; then
	e_print "ERROR" "Unable to find ${HOME}/${PRIMARY}.env"
fi
source ${HOME}/${PRIMARY}.env
typeset -r PRIMARY_SID=${ORACLE_SID}
typeset -r PRIMARY_UNQ=${ORACLE_UNQNAME}
typeset -r STANDBY_UNQ=${PRIMARY_UNQ/${PRIMARY}/${STANDBY}}

if [[ -r /etc/oracle/olr.loc ]]; then
	CRS_HOME=$(grep crs_home /etc/oracle/olr.loc |awk -F= '{print $2}')
else
	e_print "ERROR" "Unable to find Grid Infrastructure Home"
	exit 1
fi

# Generate a random port between 50000-51000 to create a listener on
typeset -r DUPL_LSNR="${PRIMARY}_DUPL"
typeset -i DUPL_PORT=$(( $RANDOM %1000 + 50000 ))

# Get the Listener's IPs
typeset -r SCAN_HOST="emeaexacsvm1-1bcej-scan.sub12170906420.vcnexacs.oraclevcn.com"
typeset -r LSNR_HOST=$($ORACLE_HOME/bin/srvctl config nodeapps -n $(hostname) |grep "VIP IPv4" |awk -F": " '{print $2}')
typeset -r DOMAIN=$(${ORACLE_HOME}/bin/srvctl config database -db ${ORACLE_UNQNAME} |grep "Domain:" |awk -F ": " '{print $2}')
typeset -r PWD_FILE=$(${ORACLE_HOME}/bin/srvctl config database -db ${ORACLE_UNQNAME} |grep "Password file:" |awk -F ": " '{print $2}')

typeset -r PRIMARY_CONN="${LSNR_HOST}:1521/${PRIMARY_UNQ}.${DOMAIN}"
typeset -r STANDBY_CONN="${LSNR_HOST}:${DUPL_PORT}/${STANDBY_UNQ}.${DOMAIN}"
#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------
e_print "INFO" "Grid Infra Home:    ${CRS_HOME}"
e_print "INFO" "Primary Database:   ${PRIMARY} (${PRIMARY_SID})"
e_print "INFO" "Primary Connection: ${PRIMARY_CONN}"
e_print "INFO" "Standby Database:   ${STANDBY}"
e_print "INFO" "Standby Connection: ${STANDBY_CONN}"
e_print "INFO" "Oracle Home:        ${ORACLE_HOME}"
e_print "INFO" "TNS_ADMIN:          ${TNS_ADMIN}"
e_print "INFO" "Listener Port:      ${DUPL_PORT}"

# 1) Boostrap Duplicate User password on Primary
boot_pwd "${PRIMARY}" "${STANDBY}" "${PWD_FILE}"

# 2) Add temporary static listener entry on Standby
dupl_lsnr "ADD" "${DUPL_LSNR}" "${DUPL_PORT}" "${STANDBY_UNQ}.${DOMAIN}" "${STANDBY}"

# 3) Manager SRLs
manage_srl "${PRIMARY}"

# 3) Create Standby init.ora for clone
typeset -r PFILE="/tmp/init${STANDBY}.ora"
stdby_pfile "${PRIMARY}" "${STANDBY}" "${PFILE}"
RC=$?
if (( ${RC} == 0 )); then
	dupl_db "SPFILE" "${PRIMARY}" "${PRIMARY_CONN}" "${STANDBY}" "${STANDBY_CONN}" "${PFILE}" "${DOMAIN}"
	RC=$?
fi

# 4) Delete temporary static listener entry on Standby
dupl_lsnr "DEL" "${DUPL_LSNR}"

# 5) Setup DGMGRL
if (( ${RC} == 0 )); then
	export ORACLE_SID=${PRIMARY_SID}
	dgmgrl_config "${DG_CONFIG_NAME}" "${PRIMARY_UNQ}" "${PRIMARY_CONN}" "PRIMARY"
	dgmgrl_config "${DG_CONFIG_NAME}" "${STANDBY_UNQ}" "${PRIMARY_CONN/${PRIMARY}/${STANDBY}}" "STANDBY"
else
	dgmgrl_remove "${DG_CONFIG_NAME}" "${STANDBY_UNQ}"
fi