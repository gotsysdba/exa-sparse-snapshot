set serveroutput on feedback off echo off
whenever sqlerror exit 1
DECLARE
	l_sql       varchar2(2048);	
	l_srl_cnt   number := 0;
	l_srl_grp   number := 0;
BEGIN
	FOR orl IN (select THREAD#, max(bytes/1024) SIZE_K, count(*) CNT from v$log group by THREAD#) LOOP
		-- If no SRL's will hit the NO_DATA_FOUND Exception to create
		SELECT count(*) into l_srl_cnt from v$standby_log where THREAD#=orl.THREAD# group by THREAD#;
		IF orl.cnt+1 = l_srl_cnt THEN
			dbms_output.put_line('No SRLs Required');
		ELSIF orl.cnt+1 > l_srl_cnt THEN
			dbms_output.put_line('Creating SRLs');
			FOR new_srl IN 1..((orl.CNT+1)-l_srl_cnt) LOOP
				l_sql := 'alter database add standby logfile thread '||orl.THREAD#||' size '||orl.SIZE_K||'K';
				dbms_output.put_line(l_sql);
				execute immediate l_sql;
			END LOOP;
		ELSIF orl.cnt+1 < l_srl_cnt THEN
			dbms_output.put_line('Deleting SRLs');
			FOR del_srl IN 1..(l_srl_cnt-(orl.CNT+1)) LOOP
				SELECT MAX(group#) INTO l_srl_grp FROM v$standby_log WHERE THREAD#=orl.THREAD#;
				l_sql := 'alter database drop standby logfile group '||l_srl_grp;
				dbms_output.put_line(l_sql);
				execute immediate l_sql;
			END LOOP;
		END IF;
	END LOOP;
EXCEPTION WHEN NO_DATA_FOUND THEN
	dbms_output.put_line('Creating SRLs.');
	FOR orl IN (select THREAD#, max(bytes/1024) SIZE_K, count(*) CNT from v$log group by THREAD#) LOOP
		FOR new_srl IN 1..((orl.CNT+1)) LOOP
			l_sql := 'alter database add standby logfile thread '||orl.THREAD#||' size '||orl.SIZE_K||'K';
			dbms_output.put_line(l_sql);
			execute immediate l_sql;
		END LOOP;
	END LOOP;
END;
/