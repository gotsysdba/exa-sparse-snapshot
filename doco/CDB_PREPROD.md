# CDB Pre-Production Database
Quickly create a Pre-Production Sparse Snapshot database for testing code releases prior to deployment to Production.

## Prerequisites
An existing Dataguard Physical Standby Database:
* The Standby *should not* be used for Disaster Recovery
* The Standby *should* be registered with CRS
* The Standby *should* be registered with Datagaurd Broker (recommended: MaxPerformance/ASYNC)
* The Standby can either be directly configured with Production or a Cascade Standby off an existing Production
Standby

## Variations
Depending on the lifetime of the Pre-Production database, the amount of Production redo generaated, and archivelog retention policies; variations to the proof-of-concept may be required for Production use.

These variations include, but are not limited to:
* The use of [Snapshot Standby](https://www.oracle.com/webfolder/technetwork/tutorials/obe/db/11g/r2/prod/ha/dataguard/usingsnapshot/usingsnapshot.htm) (not to be confused with Sparse Snapshots)
* Refreshing the Standby using "RECOVER FROM ... SERVICE"
* Rebuilding the Standby completely

## Process
For Proof-of-Concept purposes it is assumed that Producton archive logs are maintained for the duration of the Sparse Pre-Production database and will be used to "catch-up" the Physical Standby used for the TestMaster.

The Standby Database in this POC is **TSTMSTR_FRA1QM**


### Step 1: Convert Standby to TestMaster
![Step1](/images/FullStep1.png)

`[oracle@exadata]$ ./sparse_ctrl.ksh -a CONVERT -b TSTMSTR_FRA1QM`

```
  INFO: CRS Installed and Running at /u01/app/19.0.0.0/grid
  INFO: Storing TestMaster files in /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM
  INFO: Running /u01/app/19.0.0.0/grid/bin/asmcmd --nocp --privilege sysdba lsattr -ml cell.sparse_dg
  INFO: Found Sparse Diskgroup: SPRC1
  INFO: Using Sparse Diskgroup: +SPRC1
  INFO: ############################################################
  INFO: # Deferring Redo Transport
  INFO: ############################################################
  INFO: Running: dgmgrl -silent / as sysdba "show configuration"
  INFO: Running: dgmgrl -silent / as sysdba "edit database 'TSTMSTR_FRA1QM' set property logshipping=OFF;"
  INFO: Running: dgmgrl -silent / as sysdba "edit database 'TSTMSTR_FRA1QM' set state=APPLY-OFF;"
  INFO: ############################################################
  INFO: # Preparing Files to use Standby as the TestMaster
  INFO: ############################################################
  INFO: Running SQL> CREATE PFILE='/home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/tmorig_pfile.ora' from SPFILE;
  INFO: Source Diskgroup: +DATAC1
  INFO: Generating Controlfile Trace to: /u02/app/oracle/diag/rdbms/tstmstr_fra1qm/TSTMSTR/trace
  INFO: Running SQL> ALTER SESSION SET TRACEFILE_IDENTIFIER='CNTRL_TRC';
			               ALTER DATABASE BACKUP CONTROLFILE TO TRACE;
  INFO: Modified trace to /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/tmorig_control.trc
  INFO: Spooling to /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/tm_df_rename.sql
  INFO: Spooling to /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/asm_mkdir.sh
  INFO: Spooling to /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/tm_rw.sql
  INFO: ############################################################
  INFO: # Shutting Down Testmaster TSTMSTR_FRA1QM
  INFO: ############################################################
```

### Step 2: Create Pre-Production Sparse Clone
![Step2](/images/FullStep2.png)

`[oracle@exadata]$  ./sparse_ctrl.ksh -a CLONE -b TSTMSTR_FRA1QM -c PREPROD`

```
  INFO: CRS Installed and Running at /u01/app/19.0.0.0/grid
  INFO: Storing TestMaster files in /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM
  INFO: Running /u01/app/19.0.0.0/grid/bin/asmcmd --nocp --privilege sysdba lsattr -ml cell.sparse_dg
  INFO: Found Sparse Diskgroup: SPRC1
  INFO: Using Sparse Diskgroup: +SPRC1
  INFO: ############################################################
  INFO: # Preparing Files for Clone
  INFO: ############################################################
  INFO: Created /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/pfile_PREPROD.ora
  INFO: Created /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/control.sql
  INFO: Created /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/df_rename.sql
  INFO: Created /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/asm_mkdir.sh
  INFO: Running /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/asm_mkdir.sh
ASMCMD: +SPRC1/PREPROD/D554F5F1644C84F6E053DD00000AFC10/DATAFILE/
ASMCMD: +SPRC1/PREPROD/D5551E8FBF00684BE053DD00000A2635/DATAFILE/
ASMCMD: +SPRC1/PREPROD/DATAFILE/
  INFO: Running SQL> startup nomount pfile=/home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/pfile_PREPROD.ora
  INFO: Running SQL> @/home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/control.sql
  INFO: Running SQL> @/home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD/df_rename.sql
  INFO: Running SQL> ALTER DATABASE OPEN RESETLOGS;
```

### Step 3: Drop Pre-Production Sparse Clone
![Step3](/images/FullStep3.png)

`[oracle@exadata]$  ./sparse_ctrl.ksh -a DROP -b TSTMSTR_FRA1QM -c PREPROD`

```
  INFO: CRS Installed and Running at /u01/app/19.0.0.0/grid
  INFO: Storing TestMaster files in /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM
  INFO: Running /u01/app/19.0.0.0/grid/bin/asmcmd --nocp --privilege sysdba lsattr -ml cell.sparse_dg
  INFO: Found Sparse Diskgroup: SPRC1
  INFO: Using Sparse Diskgroup: +SPRC1
  INFO: ############################################################
  INFO: # Dropping PREPROD Clone associated with TSTMSTR_FRA1QM
  INFO: ############################################################
  INFO: Dropping Clone PREPROD
        database dropped
        Recovery Manager complete.
  INFO: Removing SPRC1/PREPROD/D554F5F1644C84F6E053DD00000AFC10/
  INFO: Removing SPRC1/PREPROD/D5551E8FBF00684BE053DD00000A2635/
  INFO: Removing SPRC1/PREPROD/DATAFILE/
  INFO: Removing /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/PREPROD
```

### Step 4: Convert TestMaster to Standby
![Step4](/images/FullStep4.png)

`[oracle@exadata]$  ./sparse_ctrl.ksh -a REVERT -b TSTMSTR_FRA1QM`
```
  INFO: CRS Installed and Running at /u01/app/19.0.0.0/grid
  INFO: Storing TestMaster files in /home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM
  INFO: Running /u01/app/19.0.0.0/grid/bin/asmcmd --nocp --privilege sysdba lsattr -ml cell.sparse_dg
  INFO: Found Sparse Diskgroup: SPRC1
  INFO: Using Sparse Diskgroup: +SPRC1
  INFO: ############################################################
  INFO: # Dropping Clones associated with TSTMSTR_FRA1QM
  INFO: ############################################################
  INFO: ############################################################
  INFO: # Starting up Testmaster TSTMSTR_FRA1QM (TSTMSTR)
  INFO: ############################################################
  INFO: Running SQL> @/home/oracle/SPARSE_CLONE/TSTMSTR_FRA1QM/tm_rw.sql
  INFO: ############################################################
  INFO: # Resuming Redo Transport
  INFO: ############################################################
  INFO: Running: dgmgrl -silent / as sysdba "edit database 'TSTMSTR_FRA1QM' set state=APPLY-ON;"
DGMGRL: Connected to "TSTMSTR_FRA1QM"
DGMGRL: Error: 
DGMGRL: ORA-16525: The Oracle Data Guard broker is not yet available.
  INFO: Running: dgmgrl -silent / as sysdba "edit database 'TSTMSTR_FRA1QM' set property logshipping=ON;"
DGMGRL: Connected to "TSTMSTR_FRA1QM"
DGMGRL: Configuration details cannot be determined by DGMGRL
  INFO: Running: dgmgrl -silent / as sysdba "show configuration"
DGMGRL: Connected to "TSTMSTR_FRA1QM"
DGMGRL: Configuration - dg_sparse
DGMGRL:   Protection Mode: MaxPerformance
DGMGRL:   Members:
DGMGRL:   JLSPRP_fra1qm - Primary database
DGMGRL:     TSTMSTR_FRA1QM - Physical standby database 
DGMGRL: Fast-Start Failover:  Disabled
DGMGRL: Configuration Status:
DGMGRL: SUCCESS   (status updated 36 seconds ago)
```