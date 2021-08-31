## Prerequisites
### Exadata and Sparse Diskgroup
*Exadata with existing Sparse Diskgroups  
*The minimum RDBDMS version: RDBMS_19.11.0.0.0DBRU_LINUX.X64_210223 (`$ORACLE_HOME/OPatch/datapatch -version`)

### ASM Access Control
As the `grid` OS user, log into ASM as SYSASM and enable access control for the `oracle` user on the DATA% and SPRC% diskgroups:
```
sqlplus / as sysasm
alter diskgroup DATAC1 set attribute 'ACCESS_CONTROL.ENABLED'='TRUE';
alter diskgroup DATAC1 add user 'oracle';
alter diskgroup SPRC1 set attribute 'ACCESS_CONTROL.ENABLED'='TRUE';
alter diskgroup SPRC1 add user 'oracle';
```