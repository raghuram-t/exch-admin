#region : Header
# ==========================================================
# System  : MailQ
# Script  : Get-ExchangeOnPremisesMailQSnapshot.ps1
# Author  : Email Team
# Created : November 2026
# Version : 1.0 - First release. One snapshot of the queues,
#           returned as an object or shown as a report.
# Target  : Exchange on-premises transport queues
#           (Exchange Online to follow)
#
# Purpose :
#   During a mail outage the team needs one calm, clear
#   answer: how much mail is waiting, and where.
#
#   This script takes one snapshot of the transport queues
#   and judges each queue and each server by one rule: the
#   number of messages waiting. It does this once and ends.
#
# Usage :
#   .\Get-ExchangeOnPremisesMailQSnapshot.ps1
#       Returns the snapshot as an object, for other tools.
#
#   .\Get-ExchangeOnPremisesMailQSnapshot.ps1 -ShowReport
#       Shows the snapshot on screen as a report.
#
# Used by :
#   - People at the console, with -ShowReport.
#   - A separate service that calls this script on a timer,
#     keeps the snapshots, and shows them on a web page.
#
# Not in this script, on purpose :
#   - No loop. Running for hours is the job of the service,
#     which can put a deadline on every poll. Anyone who
#     wants a loop at the console can wrap the script.
#   - No history, and no comparison with earlier polls.
#     Those belong to the service, next to its database.
#   - No email notification. In a mail outage the team must
#     not depend on mail to hear about it.
#   - Queue status is not judged, only the message count. A
#     queue in Retry usually reflects someone else's system.
#
# Data :
#   This version returns dummy data. Search this file for
#   PLUG-IN POINT to find the two places to change for real
#   data.
#
# Running it twice :
#   Safe. The script only reads. It changes nothing in
#   Exchange and keeps nothing between runs.
# ==========================================================
#endregion : Header

#region : Parameters
# ----------------------------------------------------------
# PARAMETERS
#
# Without any parameter, the script returns one snapshot as
# an object, for other tools to use.
#
# With -ShowReport, it shows the snapshot on screen as a
# report for people to read, and returns nothing.
# ----------------------------------------------------------
[CmdletBinding()]
param (
    [switch] $ShowReport
)
#endregion : Parameters

#region : Settings and Types
# ----------------------------------------------------------
# STRICT MODE
#
# Turns silent mistakes into visible errors: a mistyped
# variable name, a property that does not exist. Without it
# PowerShell treats such a mistake as an empty value and
# carries on, which could show a server as Normal when it is
# not.
#
# Strict mode raises the error. It does not stop the script.
# Acting on the error is the job of the try and catch around
# each server's turn, which records that server as Unknown.
# ----------------------------------------------------------
Set-StrictMode -Version Latest

# ----------------------------------------------------------
# HEALTH: the three answers this script can give
#
# Every queue and every server is Normal, High, or Unknown.
# The answers are defined once, here, as a type. No function
# types them by hand, so a typo cannot make two parts of the
# script disagree.
#
# High means more mail is waiting than our threshold allows.
# It describes the count. It does not say why.
#
# Unknown means we could not read the data needed to judge.
# It is listed first on purpose: a value that was never set
# then reads as Unknown, never as Normal.
#
# Each label is one plain word, so the card prints it as it
# is, with no translation.
# ----------------------------------------------------------
enum Health {
    Unknown
    Normal
    High
}

#endregion : Settings and Types

#region : Exchange Live Call
# ----------------------------------------------------------
# FUNCTION: Get-ExchangeQueueDataByServer
#
# The only place in this script that talks to Exchange.
# Takes one server name and returns that server's queues,
# one object per queue, holding raw facts exactly as
# Exchange reports them. No verdicts and no totals are added
# here; those belong to the functions that follow.
#
# THE CONTRACT
#   Every object returned has exactly these properties.
#   Everything after this function depends on them.
#
#   ServerName     text          the server that was asked
#   QueueIdentity  text          for example EXCH01\1201
#   MessageCount   whole number  messages in the queue
#   QueueStatus    text          for example Ready or Retry
#   Velocity       number        may be negative or fractional
#   NextHopDomain  text          where the queue delivers to
#   DeliveryType   text          ShadowRedundancy marks a
#                                shadow queue
#
#   When the server cannot be read, or returns no queues,
#   this function throws an error. It does not decide what
#   that means. The caller does.
#
# PLUG-IN POINT 1 of 2
#   This version returns dummy data. To use real data,
#   replace the body of this function with a call to
#   Get-Queue for the one server, and copy each fact into
#   the properties above. Keep the contract unchanged.
#
#   When plugging in, make sure that:
#   - no result cap applies. The default is 1000 queues.
#   - a failed call raises an error that try/catch can see.
#   - an empty result throws, instead of returning nothing.
#   - each value is converted to the type named above.
# ----------------------------------------------------------
function Get-ExchangeQueueDataByServer {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string] $ServerName
    )

    # The Submission queue on EXCH01, as Exchange reports it.
    $SubmissionQueue = [PSCustomObject]@{
        ServerName    = 'EXCH01'
        QueueIdentity = 'EXCH01\Submission'
        MessageCount  = 42
        QueueStatus   = 'Ready'
        Velocity      = 0
        NextHopDomain = 'Submission'
        DeliveryType  = 'Undefined'
    }

    # A delivery queue on EXCH01 that Exchange reports as Retry.
    $RetryQueue = [PSCustomObject]@{
        ServerName    = 'EXCH01'
        QueueIdentity = 'EXCH01\1201'
        MessageCount  = 3700
        QueueStatus   = 'Retry'
        Velocity      = -9.8
        NextHopDomain = 'contoso.mail.onmicrosoft.com'
        DeliveryType  = 'SmartHostConnectorDelivery'
    }

    # A delivery queue on EXCH02 that Exchange reports as Active.
    $ActiveQueue = [PSCustomObject]@{
        ServerName    = 'EXCH02'
        QueueIdentity = 'EXCH02\1305'
        MessageCount  = 790
        QueueStatus   = 'Active'
        Velocity      = 0.5
        NextHopDomain = 'fabrikam.com'
        DeliveryType  = 'DnsConnectorDelivery'
    }

    # A shadow redundancy queue on EXCH02, as Exchange reports it.
    $ShadowQueue = [PSCustomObject]@{
        ServerName    = 'EXCH02'
        QueueIdentity = 'EXCH02\Shadow\1410'
        MessageCount  = 180
        QueueStatus   = 'Ready'
        Velocity      = 0
        NextHopDomain = 'exch01.contoso.com'
        DeliveryType  = 'ShadowRedundancy'
    }

    # EXCH03 plays the part of a server that cannot be read.
    $IsServerThatCannotBeRead = $ServerName -eq 'EXCH03'

    if ($IsServerThatCannotBeRead) {
        throw "No answer from server $ServerName"
    }

    $AllDummyQueues = @(
        $SubmissionQueue
        $RetryQueue
        $ActiveQueue
        $ShadowQueue
    )

    $QueuesOnServer = @(
        $AllDummyQueues |
            Where-Object ServerName -eq $ServerName
    )

    # A server that returns no queues is reported as trouble,
    # as the contract above promises.
    $ServerReturnedNoQueues = $QueuesOnServer.Count -eq 0

    if ($ServerReturnedNoQueues) {
        throw "No queues returned by server $ServerName"
    }

    Write-Output $QueuesOnServer
}
#endregion : Exchange Live Call

#region : Working out health
# ----------------------------------------------------------
# FUNCTION: Get-HealthByQueue
#
# Looks at one queue and answers with its Health:
# Normal or High.
#
# The rule is the message count alone. A queue holding more
# messages than its threshold is considered as 'High'.
#
# There are two thresholds because there are two kinds of
# queue. Shadow redundancy queues hold safety copies of mail
# in transit and sit in the hundreds on a normal day, so
# they get their own, higher threshold. Every other queue
# uses the standard one.
#
# The thresholds are the same for every server and every
# queue, so they are set once, at the top of this function.
# They are starting values. We tune them once we have days
# of history, and they move to settings when that is useful.
#
# Queue status is deliberately not judged. A queue in Retry
# or Suspended usually reflects a problem in someone else's
# system. The count reflects mail waiting on ours.
#
# This is the only place that passes judgement on a queue.
# ----------------------------------------------------------
function Get-HealthByQueue {
    [CmdletBinding()]
    [OutputType([Health])]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Queue
    )

    # How much mail a queue may hold before it counts as High.
    $StandardQueueThreshold = 50
    $ShadowQueueThreshold   = 250

    $IsShadowRedundancyQueue = $Queue.DeliveryType -eq 'ShadowRedundancy'

    if ($IsShadowRedundancyQueue) {
        $ThresholdForThisQueue = $ShadowQueueThreshold
    }
    else {
        $ThresholdForThisQueue = $StandardQueueThreshold
    }

    $HasTooMuchMailWaiting = $Queue.MessageCount -gt $ThresholdForThisQueue

    if ($HasTooMuchMailWaiting) {
        return [Health]::High
    }

    return [Health]::Normal
}

# ----------------------------------------------------------
# FUNCTION: Get-HealthSummaryByServer
#
# Takes the queues of one server, each already carrying its
# Health, and answers with one summary for that server:
# whether it is Normal or High, and how much mail is waiting
# there in total.
#
# A server is High when any queue on it is. No new judgement
# is made here. The server only repeats what
# Get-HealthByQueue already said about its queues.
#
# Shadow redundancy queues are left out of both the total
# and the health. They hold safety copies, not mail waiting
# for delivery, and would make every server look hundreds of
# messages fuller than it is.
#
# This function is only called for a server that was read
# and has queues. A server that could not be read never
# reaches it. The caller records that server as Unknown.
# ----------------------------------------------------------
function Get-HealthSummaryByServer {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string] $ServerName,

        [Parameter(Mandatory)]
        [PSCustomObject[]] $QueuesOnServer
    )

    $QueuesWaitingForDelivery = $QueuesOnServer |
        Where-Object DeliveryType -ne 'ShadowRedundancy'

    # Add up the mail waiting on this server.
    $QueuedTotal = 0

    foreach ($Queue in $QueuesWaitingForDelivery) {
        $QueuedTotal += $Queue.MessageCount
    }

    # A server is High when any queue on it is.
    $HasHighQueue = $QueuesWaitingForDelivery.Health -contains [Health]::High

    if ($HasHighQueue) {
        $ServerHealth = [Health]::High
    }
    else {
        $ServerHealth = [Health]::Normal
    }

    $HealthSummary = [PSCustomObject]@{
        ServerName  = $ServerName
        Health      = $ServerHealth
        QueuedTotal = $QueuedTotal
        Error       = $null
    }

    Write-Output $HealthSummary
}

# ----------------------------------------------------------
# FUNCTION: Get-HealthSummaryForExchangeOnPremises
#
# Takes the summaries of every on-premises server and
# answers with one summary for Exchange on-premises: how
# much mail is waiting in total, how many servers we watch,
# and how many of them could not be read.
#
# The total adds up only the servers we could read. When
# some could not be read, the total is incomplete, and the
# count of unread servers lets the card say so.
#
# When no server could be read, the total stays empty. We do
# not know it, and zero would claim that no mail is waiting.
#
# This function is for Exchange on-premises only. Exchange
# Online gives us no queues and no servers to add up, so it
# gets a function of its own when that path is built.
# ----------------------------------------------------------
function Get-HealthSummaryForExchangeOnPremises {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject[]] $HealthSummaries
    )

    $ServersNotRead = @(
        $HealthSummaries |
            Where-Object Health -eq ([Health]::Unknown)
    )

    $ServersRead = @(
        $HealthSummaries |
            Where-Object Health -ne ([Health]::Unknown)
    )

    # The total starts empty, and stays empty unless at least
    # one server could be read.
    $QueuedTotal = $null

    $HasServersRead = $ServersRead.Count -gt 0

    if ($HasServersRead) {
        $QueuedTotal = 0

        foreach ($HealthSummary in $ServersRead) {
            $QueuedTotal += $HealthSummary.QueuedTotal
        }
    }

    $EnvironmentSummary = [PSCustomObject]@{
        EnvironmentName = 'Exchange on-premises'
        QueuedTotal     = $QueuedTotal
        ServersWatched  = $HealthSummaries.Count
        ServersNotRead  = $ServersNotRead.Count
    }

    Write-Output $EnvironmentSummary
}
#endregion : Working out health

#region : Taking a snapshot
# ----------------------------------------------------------
# FUNCTION: Get-SnapshotForExchangeOnPremises
#
# Takes one poll of Exchange on-premises and hands back one
# snapshot: everything that poll gathered, held together.
#
# A snapshot carries the poll's own id, the time it was
# taken, the summary of the environment, one summary per
# server, and every judged queue.
#
# Our first rule applies here: no variable may carry data
# from an earlier server or an earlier poll. Everything the
# poll fills starts empty, and every server starts its turn
# with a clean slate.
#
# One server's trouble never hides the others. A server
# whose turn fails, for any reason, is recorded as Unknown
# with the reason, and the poll carries on.
# ----------------------------------------------------------
function Get-SnapshotForExchangeOnPremises {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string[]] $ServerNames
    )

    # Everything this poll fills. All of it starts empty, so
    # nothing from an earlier poll can be shown by mistake.
    $HealthSummaries           = @()
    $QueuesOnAllServers        = @()
    $ExchangeOnPremisesSummary = $null

    # This poll's identity and its time, both taken once,
    # before Exchange is asked.
    $PollId      = [Guid]::NewGuid()
    $PolledAtUtc = [DateTime]::UtcNow

    foreach ($ServerName in $ServerNames) {

        # Start this server with a clean slate, so nothing from
        # the previous server can leak into this one.
        $QueuesFromExchange = $null
        $QueuesOnServer     = @()
        $JudgedQueue        = $null
        $HealthSummary      = $null

        try {
            # Get this server's queues from Exchange.
            $QueuesFromExchange = Get-ExchangeQueueDataByServer -ServerName $ServerName

            # Give each queue its health, and pile the queues up.
            foreach ($Queue in $QueuesFromExchange) {
                $JudgedQueue = [PSCustomObject]@{
                    PollId        = $PollId
                    PolledAtUtc   = $PolledAtUtc
                    ServerName    = $Queue.ServerName
                    Health        = Get-HealthByQueue -Queue $Queue
                    QueueIdentity = $Queue.QueueIdentity
                    MessageCount  = $Queue.MessageCount
                    QueueStatus   = $Queue.QueueStatus
                    Velocity      = $Queue.Velocity
                    NextHopDomain = $Queue.NextHopDomain
                    DeliveryType  = $Queue.DeliveryType
                }

                $QueuesOnServer += $JudgedQueue
            }

            # Sum this server up.
            $HealthSummary = Get-HealthSummaryByServer -ServerName $ServerName -QueuesOnServer $QueuesOnServer
        }
        catch {
            # Something in this server's turn failed. Whatever was
            # gathered for it before the failure is set aside, and
            # the server is recorded as Unknown, with the reason.
            $QueuesOnServer = @()

            $HealthSummary = [PSCustomObject]@{
                ServerName  = $ServerName
                Health      = [Health]::Unknown
                QueuedTotal = $null
                Error       = $_.Exception.Message
            }
        }

        # Place this server's results in the baskets.
        $QueuesOnAllServers += $QueuesOnServer
        $HealthSummaries    += $HealthSummary
    }

    # Sum Exchange on-premises up.
    $ExchangeOnPremisesSummary = Get-HealthSummaryForExchangeOnPremises -HealthSummaries $HealthSummaries

    # Hold everything this poll gathered together as one snapshot.
    $Snapshot = [PSCustomObject]@{
        PollId             = $PollId
        PolledAtUtc        = $PolledAtUtc
        EnvironmentSummary = $ExchangeOnPremisesSummary
        ServerSummaries    = $HealthSummaries
        Queues             = $QueuesOnAllServers
    }    

    Write-Output $Snapshot
}
#endregion : Taking a snapshot

#region : Showing the Card
# ----------------------------------------------------------
# FUNCTION: Show-CardHeader
#
# Prints the top of the status card: the title, the poll's
# id and the time of the poll, between two bars.
#
# The id names exactly one poll. People can quote it to each
# other, and use it to find the same poll in the saved
# history.
#
# This is a Show function. It writes text for people to read
# and returns nothing. Every fact it prints is handed to it.
# It works nothing out for itself.
# ----------------------------------------------------------
function Show-CardHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [Guid] $PollId,

        [Parameter(Mandatory)]
        [DateTime] $PolledAtUtc
    )

    $Bar = '=' * 74

    # Written the same way on every computer, whatever its
    # regional settings. Example: 2026-11-16 03:55
    $PollTimeText = $PolledAtUtc.ToString(
        'yyyy-MM-dd HH:mm',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    Write-Host $Bar
    Write-Host 'MAILQ: EXCHANGE ON-PREMISES'
    Write-Host "Poll Id        $PollId"
    Write-Host "Poll Time      $PollTimeText UTC"
    Write-Host $Bar
}

# ----------------------------------------------------------
# FUNCTION: Show-OverallSection
#
# Prints the OVERALL section of the status card: one line
# per environment, with how much mail is waiting there now.
#
# This is a Show function. It writes text for people to read
# and returns nothing. It changes no data.
# ----------------------------------------------------------
function Show-OverallSection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ExchangeOnPremisesSummary
    )

    Write-Host ''
    Write-Host ('-' * 74)
    Write-Host 'OVERALL'
    Write-Host ('-' * 74)

    # How each column of the table is filled and shown.
    $EnvironmentColumn = @{
        Label      = 'Environment'
        Expression = 'EnvironmentName'
    }

    # N0 writes a whole number with commas: 4,532
    $NowColumn = @{
        Label        = 'Now'
        Expression   = 'QueuedTotal'
        FormatString = 'N0'
        Alignment    = 'Right'
    }

    $ExchangeOnPremisesSummary |
        Format-Table $EnvironmentColumn, $NowColumn |
        Out-Host
        
    # Say so when the total is incomplete or missing.
    $ServersWatched = $ExchangeOnPremisesSummary.ServersWatched
    $ServersNotRead = $ExchangeOnPremisesSummary.ServersNotRead
    $ServersRead    = $ServersWatched - $ServersNotRead

    $NoServerCouldBeRead    = $ServersRead -eq 0
    $SomeServersWereNotRead = ($ServersNotRead -gt 0) -and ($ServersRead -gt 0)

    if ($NoServerCouldBeRead) {
        Write-Host 'No server could be read.'
    }
    elseif ($SomeServersWereNotRead) {
        $IncompleteTotalNote =
            "The total covers $ServersRead of $ServersWatched servers. " +
            "$ServersNotRead could not be read."

        Write-Host $IncompleteTotalNote
    }
}

# ----------------------------------------------------------
# FUNCTION: Show-PerServerSection
#
# Prints the PER SERVER section of the status card: one line
# per server, with its status and how much mail is waiting
# there now. Under the table, each server that could not be
# read gets one more line giving the reason.
#
# This is a Show function. It writes text for people to read
# and returns nothing. It changes no data. The comma in a
# number such as 3,742 exists only on screen.
# ----------------------------------------------------------
function Show-PerServerSection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject[]] $HealthSummaries
    )

    Write-Host ''
    Write-Host ('-' * 74)
    Write-Host 'PER SERVER'
    Write-Host ('-' * 74)

    # How each column of the table is filled and shown.
    $ServerColumn = @{
        Label      = 'Server'
        Expression = 'ServerName'
    }

    $StatusColumn = @{
        Label      = 'Status'
        Expression = 'Health'
        Alignment  = 'Left'
    }

    # N0 writes a whole number with commas: 3,742
    $NowColumn = @{
        Label        = 'Now'
        Expression   = 'QueuedTotal'
        FormatString = 'N0'
        Alignment    = 'Right'
    }

    $HealthSummaries |
        Format-Table $ServerColumn, $StatusColumn, $NowColumn |
        Out-Host

    # Say why each unreadable server is Unknown.
    $ServersThatCouldNotBeRead = $HealthSummaries |
        Where-Object Health -eq ([Health]::Unknown)

    foreach ($HealthSummary in $ServersThatCouldNotBeRead) {
        $ServerName = $HealthSummary.ServerName
        $Reason     = $HealthSummary.Error

        Write-Host "$ServerName could not be read: $Reason"
    }
}

# ----------------------------------------------------------
# FUNCTION: Show-PerQueueSection
#
# Prints the PER QUEUE section of the status card: one line
# per queue, with its status and how much mail is waiting in
# it now.
#
# Queues that are High come first, then those that are
# Normal. Within each, the fullest queue comes first, so the
# queues that matter most are at the top of a long list.
#
# This is a Show function. It writes text for people to read
# and returns nothing. It changes no data.
# ----------------------------------------------------------
function Show-PerQueueSection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [PSCustomObject[]] $QueuesOnAllServers
    )

    Write-Host ''
    Write-Host ('-' * 74)
    Write-Host 'PER QUEUE'
    Write-Host ('-' * 74)

    # When no server could be read, there are no queues to list.
    $HasNoQueues = $QueuesOnAllServers.Count -eq 0

    if ($HasNoQueues) {
        Write-Host 'No queues could be read.'
        return
    }

    # Card order: High first, then Normal, fullest first.
    $HighQueues = @(
        $QueuesOnAllServers |
            Where-Object Health -eq ([Health]::High) |
            Sort-Object MessageCount -Descending
    )

    $NormalQueues = @(
        $QueuesOnAllServers |
            Where-Object Health -eq ([Health]::Normal) |
            Sort-Object MessageCount -Descending
    )

    $QueuesInCardOrder = $HighQueues + $NormalQueues

    # How each column of the table is filled and shown.
    $ServerColumn = @{
        Label      = 'Server'
        Expression = 'ServerName'
    }

    $QueueColumn = @{
        Label      = 'Queue'
        Expression = 'QueueIdentity'
    }

    $StatusColumn = @{
        Label      = 'Status'
        Expression = 'Health'
        Alignment  = 'Left'
    }

    # N0 writes a whole number with commas: 3,700
    $NowColumn = @{
        Label        = 'Now'
        Expression   = 'MessageCount'
        FormatString = 'N0'
        Alignment    = 'Right'
    }

    $QueuesInCardOrder |
        Format-Table $ServerColumn, $QueueColumn, $StatusColumn, $NowColumn |
        Out-Host
}
#endregion : Showing the Card

#region : Main
# ----------------------------------------------------------
# MAIN: one poll
#
# Everything above this bar is a function. Functions must be
# defined before they are called, so MAIN always stays last.
#
# MAIN tells the story of one poll: take a snapshot, then
# either hand it back as an object for other tools, or show
# it on screen as a report for people. All gathering happens
# inside the snapshot function, and all printing inside the
# Show functions.
# ----------------------------------------------------------

# PLUG-IN POINT 2 of 2
# The servers we watch. This version uses three dummy names,
# and EXCH03 plays a server that cannot be read. To use real
# data, replace this list with the real server names, or
# with a call that discovers them.
$ServerNames = @('EXCH01', 'EXCH02', 'EXCH03')

# The snapshot starts empty, so a snapshot from an earlier
# run can never be shown by mistake.
$Snapshot = $null

# Take a snapshot of Exchange on-premises.
$Snapshot = Get-SnapshotForExchangeOnPremises -ServerNames $ServerNames

if ($ShowReport) {
    # Show the snapshot on screen, as a report for people.
    Show-CardHeader -PollId $Snapshot.PollId -PolledAtUtc $Snapshot.PolledAtUtc
    Show-OverallSection -ExchangeOnPremisesSummary $Snapshot.EnvironmentSummary
    Show-PerServerSection -HealthSummaries $Snapshot.ServerSummaries
    Show-PerQueueSection -QueuesOnAllServers $Snapshot.Queues
}
else {
    # Hand the snapshot back as an object, for other tools.
    Write-Output $Snapshot
}
#endregion : Main

# ==========================================================
# END OF SCRIPT
# ==========================================================