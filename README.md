# Overview
Oracle Exadata Snapshots provide space efficent clones of Oracle Databases for testing/development (non-Production) purposes while leveraging Exadata performance and availability features.  Exadata Snapshots can be created at the PDB, CDB, or non-CDB level, and depending on the requirements, at point-in-time.

Main benefits over other solutions include:
* Utilises existing, familiar Oracle technologies (Dataguard/Goldengate)
* No additional network requirements
* No network latency impacting performance (I/O bus is not Ethernet)
* No 3rd-Party black-box appliances
* Offers full end-to-end performance and high availability (HA) testing

More information about Exadata Snapshots can be found in the [Official Documentation](https://docs.oracle.com/en/engineered-systems/exadata-database-machine/sagug/exadata-storage-server-snapshots.html#GUID-78F67DD0-93C8-4944-A8F0-900D910A06A0)

## TestMaster Concept
The "TestMaster" is an Oracle DB (incl. PDBs) whose instance(s) have no Write access to the physical datafiles for the duration that dependant snapshots exist.  This is achived in one of two ways: The (P)DB is closed; or the (P)DB is in a Read-Only state.  "Converting" a (P)DB into a TestMaster is the process required to achive the closed or Read-Only state. 

When replication technology, e.g. Dataguard or Goldengate, is used, part of the conversion process includes stopping, or redirecting, replication to prevent unintented disruption to the source DB.

## Observations and Considerations
* Controlfiles and Online REDO are always FULL (not Sparse Copies).  Keep this in mind in regards to diskspace, especially around Online REDO sizes.
* The Offical Documentation demonstrates new ASM directories in the SPARSE Diskgroup for each SnapshotDB.  This is not required as datafiles can be uniquely named during the sparse clones and placed in a single ASM directory.  Creating new directories will require interaction with ASM to both create the new directory and grant ACL access.  
* The strategy taken in regards to ASM directories may simplify or complicate cleanup activities depending on the requirements.
* For Point-In-Time Scenarios, you must maintain the files generated during each Sparse TestMaster creation in order to create SnapshotDBs on older TestMaster files.  This is required as new Production (Primary) datafiles/PDBs may be replicated to the active Sparse TestMaster.
* The Dataguard database used for cloning can be replicated from the Primary (use Maximum Availability to avoid compromising the availability) or from another Standby.
* With an Active Dataguard License, the Datagaurd database used for cloning can be Opened Read-Only if required.


# Use Cases
## Prerequisites
**Exadata and Sparse Diskgroup**
* Oracle Exadata Database Machine with Sparse Diskgroups
* Required Patches/Level  (`$ORACLE_HOME/OPatch/datapatch -version`)
  * 19.11 RDBMS:  RDBMS_19.11.0.0.0DBRU_LINUX.X64_210223
  * 19.12 RDBMS:  33656608

**ASM Access Control**
As the `grid` OS user, log into ASM as SYSASM and enable access control for the `oracle` user on the DATA and SPRC diskgroups, for example:
```
sqlplus / as sysasm
alter diskgroup DATAC1 set attribute 'ACCESS_CONTROL.ENABLED'='TRUE';
alter diskgroup DATAC1 add user 'oracle';
alter diskgroup SPRC1 set attribute 'ACCESS_CONTROL.ENABLED'='TRUE';
alter diskgroup SPRC1 add user 'oracle';

REM Verify 
select g.name, u.os_name 
  from v$asm_user u, v$asm_diskgroup g 
 where g.group_number = u.group_number;
```

## CDB Pre-Production Database
A full TestMaster, identical to production, that needs to be refreshed regularly.  The TestMaster database is an Oracle Dataguard, physical standby dedicated to this purpose.  A single sparse snapshot is created and dropped as part of a software delivery lifecycle.

[Details found here.](doco/CDB_PREPROD.md)

## PDB Scrubbed Development Databases
A cloned and scrubbed TestMaster used for development purposes.  The TestMaster database is a Pluggable Database (PDB),cloned from a Production PDB and Scrubbed prior to creating snapshots.  Multiple sparse snapshots are created and dropped, on demand, by individual developers to create isolated environments.

[Details found here.](doco/PDB_DEV.md)

## CDB Point-in-Time Database
Mutlipe full TestMaster databases, identical to the source at specific point-in-times.  The TestMaster databases are Oracle Dataguard, physical standby dedicated to this purpose.  Replication is redirected to Sparse Standby's while earlier TestMasters are used for snapshots.

Details found here.

## PDB Point-in-Time Database
Multiple PDB TestMaster databases, identical to the source at specific point-in-times.  The TestMaster PDBs are are Goldengate Targets dedicated to this purpose.  Replication is redirected to Sparse Goldengate Target PDBs  while earlier TestMasters are used for snapshots.

Details found here.