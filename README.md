# VEEAM-B-R-SQL-PostgreSQL

Many thanks for the script and template to the user: https://github.com/romainsi. The code has been rewritten to connect to the PostgreSQL database. 

This template use SQL Query to discover VEEAM Backup jobs, Veeam BackupCopy, Veeam BackupSync, Veeam Tape Job, Veeam FileTape, Veeam Agent, Veeam Replication, All Repositories.
Powershell get all informations via SQL and send it to zabbix server/proxy with json.

- Work with Veeam backup & replication V12 (actually ok on 12.3.0.310)
- Work with Zabbix 6.4

## Items

- Total number of VEEAM jobs
- Master Item for Veeam jobs and repository Informations

## Triggers

- [WARNING] => No data in RepoInfo
- [WARNING] => No data on Jobs

## Discovery Jobs

### Items discovery Veeam Job, Replication, FileTape, Tape, Sync, Copy, Agent

- Result
- Progress
- Last end time
- Last run time
- Last job duration
- If failed Job : Last Reason
- If failed : Is retry ?

### Items discovery Veeam Repository

- Remaining space in repository
- Total space in repository
- Percent free space
- Out of date

### Triggers discovery Veeam jobs Backup, Copy, Tape, BackupSync

- [HIGH] => Job has FAILED
- [HIGH] => Job has FAILED (With Retry)
- [AVERAGE] => Job has completed with warning
- [AVERAGE] => Job has completed with warning (With Retry)
- [HIGH] => Job is still running (8 hours)

### Triggers discovery Veeam Repository

- [HIGH] => Less than 20% remaining on the repository
- [HIGH] => Information is out of date

## Setup

1. Install the Zabbix agent 2 on your host.
2. Register access for the zabbixveeam user in the pg_hba.conf file:
    # TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             zabbixveeam                             md5

# IPv4 local connections:
host    all             zabbixveeam     127.0.0.1/32            md5
host    all             all             127.0.0.1/32            sspi map=veeam

3. With psql : Create User/Pass with reader rights , permit to connect with local user in sql settings and specify the default database. With psql.exe (Change password "CHANGEME" with something more secure):

    ```sql
    -- Переключение на базу данных VeeamBackup
\c VeeamBackup;

-- Создание пользователя (роли) с паролем
CREATE ROLE zabbixveeam WITH LOGIN PASSWORD 'CHANGEME';

-- Назначение прав на чтение всех таблиц в базе данных
GRANT CONNECT ON DATABASE VeeamBackup TO zabbixveeam;
GRANT USAGE ON SCHEMA public TO zabbixveeam;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO zabbixveeam;

-- Если вы хотите, чтобы эти права автоматически применялись к новым таблицам
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO zabbixveeam;
    ```

4. Copy `zabbix_vbr_job.ps1` in the directory : `C:\Program Files\Zabbix Agent 2\scripts\` (create folder if not exist)
5. Add `UserParameter=veeam.info[*],powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr_job.ps1" "$1"` in zabbix_agent2.conf  
6. Import Template_Veeam_Backup_And_Replication.yaml file into Zabbix.
7. Associate Template "VEEAM Backup and Replication" to the host.  
NOTE: When importing the new template version on an existing installation please check all "Delete missing", except "Template linkage", to make sure the old items are deleted

Ajust Zabbix Agent & Server/Proxy timeout for userparameter, you can use this powershell command to determine the execution time :

```powershell
(Measure-Command -Expression{ & "C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr_job.ps1" "StartJobs"}).TotalSeconds
```
