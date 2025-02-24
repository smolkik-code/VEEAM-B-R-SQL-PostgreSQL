[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("RepoInfo", "JobsInfo", "TotalJob")]
    [System.String]$Operation
)

# Загрузка библиотеки Npgsql
Add-Type -Path "C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Npgsql\v4.0_4.0.12.0__5d8b90d52f46fda7\Npgsql.dll"

########### Adjust the following variables to match your configuration ###########
$veeamserver = 'localhost'   # Machine name where Veeam is installed
$SQLServer = 'localhost' # Database server where Veeam database is located
$SQLIntegratedSecurity = $false        # Use Windows integrated security?
$SQLuid = 'zabbixveeam'                # SQL Username when using SQL Authentication - ignored if using Integrated security
$SQLpwd = 'CHANGEME'                   # SQL user password
$SQLveeamdb = 'VeeamBackup'            # Name of Veeam database. VeeamBackup is the default

$typeNames = @{
    0     = "Job";
    1     = "Replication";
    2     = "File";
    28    = "Tape";
    51    = "Sync";
    63    = "Copy";
    4030  = "RMAN";
    12002 = "Agent backup policy";
    12003 = "Agent backup job";
    13000 = "NAS";
    14000 = "Proxmox";
}

# $jobtypes is used in SQL queries. Built automatically from the enumeration above.
$jobTypes = "($(($typeNames.Keys | Sort-Object) -join ", "))"

########### DO NOT MODIFY BELOW ###########
function Get-ConnectionString() {
    $builder = New-Object Npgsql.NpgsqlConnectionStringBuilder
    $builder.Host = $SQLServer
    $builder.IntegratedSecurity = $SQLIntegratedSecurity
    $builder.Database = $SQLveeamdb
    $builder.Username = $SQLuid
    $builder.Password = $SQLpwd
    Write-Debug "Connection String: $($builder.ConnectionString)"
    return $builder.ConnectionString
}

function Start-Connection() {
    $connectionString = Get-ConnectionString

    # Create a connection to PostgreSQL
    Write-Debug "Opening SQL connection"
    $connection = New-Object Npgsql.NpgsqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()
    if ($connection.State -notmatch "Open") {
        # Connection open failed. Wait and retry connection
        Start-Sleep -Seconds 5
        $connection = New-Object Npgsql.NpgsqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()
    }
    Write-Debug "SQL connection state: $($connection.State)"
    return $connection
}

function Get-SqlCommand {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [System.String]$Command
    )

    $Connection = $null
    # Use try-catch to avoid exceptions if connection to SQL cannot be opened or data cannot be read
    # It either returns the data read or $null on failure
    try {
        $Connection = Start-Connection
        $SqlCmd = New-Object Npgsql.NpgsqlCommand
        $SqlCmd.CommandText = $Command
        $SqlCmd.Connection = $Connection
        $SqlCmd.CommandTimeout = 0
        $SqlAdapter = New-Object Npgsql.NpgsqlDataAdapter
        Write-Debug "Executing SQL query: ##$Command##"
        $SqlAdapter.SelectCommand = $SqlCmd
        $DataSet = New-Object System.Data.DataSet
        $SqlAdapter.Fill($DataSet)
        $retval = $DataSet.Tables[0]
    }
    catch {
        $retval = $null
        # We output the error message. This gets sent to Zabbix.
        Write-Output $_.Exception.Message
    }
    finally {
        # Make sure the connection is closed
        if ($null -ne $Connection) {
            $Connection.Close()
        }
    }
    return $retval
}

function ConvertTo-Unixtimestamp {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.DateTime]$date
    )
    # Unix epoch
    [System.DateTime]$unixepoch = (get-date -date "01/01/1970 00:00:00Z")

    # Handle empty dates
    # We make this one second less than $unixepoch.
    # This makes the time calculation below return -1 to Zabbix, making the item "unsupported" while the job is running (or before it ran for the first time)
    if ($null -eq $date -or $date -lt $unixepoch) {
        $date = $unixepoch.AddSeconds(-1);
    }

    # Return the seconds elapsed between the reference date and the epoch
    return [int]((New-TimeSpan -Start $unixepoch -end $date).TotalSeconds)
}

function Get-SessionInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Object]$BackupSession
    )

    # Return $null if there is no session data
    if (!$BackupSession) {
        return $null
    }

    # Get reason for the job failure/warning
    # We get all jobs reasons from both table column and log_xml
    $Log = (([Xml]$BackupSession.log_xml).Root.Log | Where-Object { $_.Status -eq 'EFailed' }).Title
    $reason = $BackupSession.reason
    foreach ($logreason in $Log) {
        $reason += "`r`n$logreason"
    }

    # Build the output object
    Write-Debug "Building object for job: $($BackupSession.job_name)"
    $Object = [PSCustomObject]@{
        JOBID       = $BackupSession.job_id
        JOBTYPEID   = $BackupSession.job_type
        JOBTYPENAME = $typeNames[$BackupSession.job_type]
        JOBNAME     = ([System.Net.WebUtility]::HtmlEncode($BackupSession.job_name))
        JOBRESULT   = $BackupSession.result
        JOBRETRY    = $BackupSession.is_retry
        JOBREASON   = ([System.Net.WebUtility]::HtmlEncode($reason))
        JOBPROGRESS = $BackupSession.progress
        JOBSTART    = (ConvertTo-Unixtimestamp $BackupSession.creation_time.ToUniversalTime())
        JOBEND      = (ConvertTo-Unixtimestamp $BackupSession.end_time.ToUniversalTime())
    }
    return $Object
}

function Get-JobInfo() {
    Write-Debug "Entering Get-JobInfo()"

    # Get all active jobs
    $BackupJobs = Get-SqlCommand "SELECT id, name, options FROM ""bjobs"" WHERE schedule_enabled = 'true' AND type IN $jobTypes ORDER BY type, name"
    Write-Debug "Job count: $($BackupJobs.Count)"
    $return = @()
    # Get information for each active job
    foreach ($job in $BackupJobs) {
        if (([Xml]$job.options).JobOptionsRoot.RunManually -eq "False") {
            Write-Debug "Getting data for job: $($job.name)"
            # Get backup jobs session information
            $LastJobSessions = Get-SqlCommand "SELECT job_id, job_type, job_name, result, is_retry, progress, creation_time, end_time, log_xml, reason
            FROM ""backup.model.jobsessions""
            INNER JOIN ""backup.model.backupjobsessions"" 
            ON ""backup.model.jobsessions"".id = ""backup.model.backupjobsessions"".id
            WHERE job_id='$($job.id)'
            ORDER BY creation_time DESC
            LIMIT 2"
            $LastJobSession = $LastJobSessions | Sort-Object end_time -Descending | Select-Object -First 1
                # Exception BackupSync continuous state
                if ($LastJobSession.job_type -like '51' -and $LastJobSession.state -like '9') { 
                $LastJobSession = $LastJobSessions | Sort-Object end_time -Descending | Select-Object -Last 1
                }
            $sessionInfo = Get-SessionInfo $LastJobSession
            $return += $sessionInfo
        }
    }
    Write-Verbose "Got job information. Number of jobs: $($return.Count)"
    # Convert data to JSON
    $return = ConvertTo-Json -Compress -InputObject @($return)
    Write-Output $return
}

function Get-RepoInfo() {
    Write-Debug "Entering Get-RepoInfo()" 
    Write-Debug "Veeam server: $veeamserver"
    # Get data from WIM class
    $repoinfo = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS

    $return = @()
    # Build the output object
    foreach ($item in $repoinfo) {
        Write-Debug "Repository $($item.NAME)"
        $Object = [PSCustomObject]@{
            REPONAME      = ([System.Net.WebUtility]::HtmlEncode($item.NAME))
            REPOCAPACITY  = $item.Capacity
            REPOFREE      = $item.FreeSpace
            REPOOUTOFDATE = $item.OutOfDate
        }
        $return += $Object
    }
    Write-Debug "Repository count: $($return.Count)"

    # Convert data to JSON
    $return = ConvertTo-Json -Compress -InputObject @($return)
    Write-Output $return
}

function Get-Totaljob() {
    $BackupJobs = Get-SqlCommand "SELECT COUNT(jobs.name) as JobCount
        FROM JobsView jobs 
        WHERE Schedule_Enabled = 'true' AND type IN $jobTypes"
    Write-Debug $BackupJobs.ToString()
    if ($null -ne $BackupJobs) {
        Write-Output $BackupJobs.JobCount
    }
    else {
        Write-Output "-- ERROR -- : No data available. Check configuration"
    }
}

If ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

Write-Debug "Job types: $jobTypes"
Write-Debug "Veeam server: $veeamserver"
Write-Debug "SQL server: $SQLServer"
switch ($Operation) {
    "RepoInfo" {
        Get-RepoInfo
    }
    "JobsInfo" {
        Get-JobInfo
    }
    "TotalJob" {
        Get-Totaljob
    }
    default {
        Write-Output "-- ERROR -- : Need an option  !"
        Write-Output "Valid options are: RepoInfo, JobsInfo or TotalJob"
        Write-Output "This script is not intended to be run directly but called by Zabbix."
    }
}
