# TeamsGroupsActivityReport.PS1
# A script to check the activity of Microsoft 365 Groups and Teams and report the groups and teams that might be deleted because they're not used.
# We check the group mailbox to see what the last time a conversation item was added to the Inbox folder. 
# Another check sees whether a low number of items exist in the mailbox, which would show that it's not being used.
# We also check the group document library in SharePoint Online to see whether it exists or has been used in the last 90 days.
# And we check Teams compliance items to figure out if any chatting is happening.

# Created 29-July-2016  Tony Redmond 
# V2.0 5-Jan-2018
# V3.0 17-Dec-2018
# V4.0 11-Jan-2020
# V4.1 15-Jan-2020 Better handling of the Team Chat folder
# V4.2 30-Apr-2020 Replaced $G.Alias with $G.ExternalDirectoryObjectId. Fixed problem with getting last conversation from Groups where no conversations are present.
# V4.3 13-May-2020 Fixed bug and removed the need to load the Teams PowerShell module
# V4.4 14-May-2020 Added check to exit script if no Microsoft 365 Groups are found
# V4.5 15-May-2020 Some people reported that Get-Recipient is unreliable when fetching Groups, so added code to revert to Get-UnifiedGroup if nothing is returned by Get-Recipient
#
# https://github.com/12Knocksinna/Office365itpros/blob/master/TeamsGroupsActivityReport.ps1
#
CLS
# Check that we are connected to Exchange Online, SharePoint Online, and Teams
Write-Host "Checking that prerequisite PowerShell modules are loaded..."
Try { $OrgName = (Get-OrganizationConfig).Name }
   Catch  {
      Write-Host "Your PowerShell session is not connected to Exchange Online."
      Write-Host "Please connect to Exchange Online using an administrative account and retry."
      Break }
$SPOCheck = Get-Module "Microsoft.Online.SharePoint.PowerShell"
If ($SPOCheck -eq $Null) {
     Write-Host "Your PowerShell session is not connected to SharePoint Online."
     Write-Host "Please connect to SharePoint Online using an administrative account and retry."; Break }
# From V4.3 on, we don't load the Teams module because there's a faster way to get a list of Teams and we've fetched the info from Groups
# $TeamsCheck = Get-Module "MicrosoftTeams"
#If ($TeamsCheck -eq $Null) {
#     Write-Host "Your PowerShell session is not connected to Microsoft Teams."
#     Write-Host "Please connect to Microsoft Teams using an administrative account and retry."; Break }
       
# OK, we seem to be fully connected to both Exchange Online and SharePoint Online...
Write-Host "Checking Microsoft 365 Groups and Teams in the tenant:" $OrgName

# Setup some stuff we use
$WarningDate = (Get-Date).AddDays(-90); $WarningEmailDate = (Get-Date).AddDays(-365); $Today = (Get-Date); $Date = $Today.ToShortDateString()
$TeamsGroups = 0;  $TeamsEnabled = $False; $ObsoleteSPOGroups = 0; $ObsoleteEmailGroups = 0
$Report = [System.Collections.Generic.List[Object]]::new(); $ReportFile = "c:\temp\GroupsActivityReport.html"
$CSVFile = "c:\temp\GroupsActivityReport.csv"
$htmlhead="<html>
	   <style>
	   BODY{font-family: Arial; font-size: 8pt;}
	   H1{font-size: 22px; font-family: 'Segoe UI Light','Segoe UI','Lucida Grande',Verdana,Arial,Helvetica,sans-serif;}
	   H2{font-size: 18px; font-family: 'Segoe UI Light','Segoe UI','Lucida Grande',Verdana,Arial,Helvetica,sans-serif;}
	   H3{font-size: 16px; font-family: 'Segoe UI Light','Segoe UI','Lucida Grande',Verdana,Arial,Helvetica,sans-serif;}
	   TABLE{border: 1px solid black; border-collapse: collapse; font-size: 8pt;}
	   TH{border: 1px solid #969595; background: #dddddd; padding: 5px; color: #000000;}
	   TD{border: 1px solid #969595; padding: 5px; }
	   td.pass{background: #B7EB83;}
	   td.warn{background: #FFF275;}
	   td.fail{background: #FF2626; color: #ffffff;}
	   td.info{background: #85D4FF;}
	   </style>
	   <body>
           <div align=center>
           <p><h1>Microsoft 365 Groups and Teams Activity Report</h1></p>
           <p><h3>Generated: " + $date + "</h3></p></div>"
		
# Get a list of Groups in the tenant
Write-Host "Extracting list of Microsoft 365 Groups for checking..."
[Int]$GroupsCount = 0; [int]$TeamsCount = 0; $TeamsList = @{}; $UsedGroups = $False
$Groups = Get-Recipient -RecipientTypeDetails GroupMailbox -ResultSize Unlimited | Sort-Object DisplayName
$GroupsCount = $Groups.Count
# If we don't find any groups (possible with Get-Recipient on a bad day), try to find them with Get-UnifiedGroup before giving up.
If ($GroupsCount -eq 0) { # 
   Write-Host "Fetching Groups using Get-UnifiedGroup"
   $Groups = Get-UnifiedGroup -ResultSize Unlimited | Sort-Object DisplayName 
   $GroupsCount = $Groups.Count; $UsedGroups = $True
   If ($GroupsCount -eq 0) {
     Write-Host "No Microsoft 365 Groups found; script exiting" ; break} 
} # End If

Write-Host "Populating list of Teams..."
If ($UsedGroups -eq $False) { # Populate the Teams hash table with a call to Get-UnifiedGroup
   Get-UnifiedGroup -Filter {ResourceProvisioningOptions -eq "Team"} -ResultSize Unlimited | ForEach { $TeamsList.Add($_.ExternalDirectoryObjectId, $_.DisplayName) } }
Else { # We already have the $Groups variable populated with data, so extract the Teams from that data
   $Groups | ? {$_.ResourceProvisioningOptions -eq "Team"} | ForEach { $TeamsList.Add($_.ExternalDirectoryObjectId, $_.DisplayName) } }
$TeamsCount = $TeamsList.Count

CLS
# Set up progress bar
$ProgDelta = 100/($GroupsCount); $CheckCount = 0; $GroupNumber = 0

# Main loop
ForEach ($Group in $Groups) { #Because we fetched the list of groups with Get-Recipient, the first thing is to get the group properties
   $G = Get-UnifiedGroup -Identity $Group.DistinguishedName
   $GroupNumber++
   $GroupStatus = $G.DisplayName + " ["+ $GroupNumber +"/" + $GroupsCount + "]"
   Write-Progress -Activity "Checking group" -Status $GroupStatus -PercentComplete $CheckCount
   $CheckCount += $ProgDelta;  $ObsoleteReportLine = $G.DisplayName;    $SPOStatus = "Normal"
   $SPOActivity = "Document library in use"
   $NumberWarnings = 0;   $NumberofChats = 0;  $TeamChatData = $Null;  $TeamsEnabled = $False;  $LastItemAddedtoTeams = "N/A";  $MailboxStatus = $Null
# Check who manages the group
  $ManagedBy = $G.ManagedBy
  If ([string]::IsNullOrWhiteSpace($ManagedBy) -and [string]::IsNullOrEmpty($ManagedBy)) {
     $ManagedBy = "No owners"
     Write-Host $G.DisplayName "has no group owners!" -ForegroundColor Red}
  Else {
     $ManagedBy = (Get-Mailbox -Identity $G.ManagedBy[0]).DisplayName}
# Group Age
  $GroupAge = (New-TimeSpan -Start $G.WhenCreated -End $Today).Days
# Fetch information about activity in the Inbox folder of the group mailbox  
   $Data = (Get-MailboxFolderStatistics -Identity $G.ExternalDirectoryObjectId -IncludeOldestAndNewestITems -FolderScope Inbox)
   If ([string]::IsNullOrEmpty($Data.NewestItemReceivedDate)) {$LastConversation = "No items found"}           
   Else {$LastConversation = Get-Date ($Data.NewestItemReceivedDate) -Format g }
   $NumberConversations = $Data.ItemsInFolder
   $MailboxStatus = "Normal"
  
   If ($Data.NewestItemReceivedDate -le $WarningEmailDate) {
      Write-Host "Last conversation item created in" $G.DisplayName "was" $Data.NewestItemReceivedDate "-> Obsolete?"
      $ObsoleteReportLine = $ObsoleteReportLine + " Last Outlook conversation dated: " + $LastConversation + "."
      $MailboxStatus = "Group Inbox Not Recently Used"
      $ObsoleteEmailGroups++
      $NumberWarnings++ }
   Else
      {# Some conversations exist - but if there are fewer than 20, we should flag this...
      If ($Data.ItemsInFolder -lt 20) {
           $ObsoleteReportLine = $ObsoleteReportLine + " Only " + $Data.ItemsInFolder + " Outlook conversation item(s) found."
           $MailboxStatus = "Low number of conversations"
           $NumberWarnings++}
      }

# Loop to check audit records for activity in the group's SharePoint document library
   If ($G.SharePointSiteURL -ne $Null) {
      $SPOStorage = (Get-SPOSite -Identity $G.SharePointSiteUrl).StorageUsageCurrent
      $SPOStorage = [Math]::Round($SpoStorage/1024,2) # SharePoint site storage in GB
      $AuditCheck = $G.SharePointDocumentsUrl + "/*"
      $AuditRecs = 0
      $AuditRecs = (Search-UnifiedAuditLog -RecordType SharePointFileOperation -StartDate $WarningDate -EndDate $Today -ObjectId $AuditCheck -ResultSize 1)
      If ($AuditRecs -eq $null) {
         #Write-Host "No audit records found for" $SPOSite.Title "-> Potentially obsolete!"
         $ObsoleteSPOGroups++   
         $ObsoleteReportLine = $ObsoleteReportLine + " No SPO activity detected in the last 90 days." }          
       }
   Else
       {
# The SharePoint document library URL is blank, so the document library was never created for this group
         #Write-Host "SharePoint has never been used for the group" $G.DisplayName 
        $ObsoleteSPOGroups++  
        $ObsoleteReportLine = $ObsoleteReportLine + " SPO document library never created." 
       }
# Report to the screen what we found - but only if something was found...   
  If ($ObsoleteReportLine -ne $G.DisplayName)
     {
     Write-Host $ObsoleteReportLine 
     }
# Generate the number of warnings to decide how obsolete the group might be...   
  If ($AuditRecs -eq $Null) {
       $SPOActivity = "No SPO activity detected in the last 90 days"
       $NumberWarnings++ }
   If ($G.SharePointDocumentsUrl -eq $Null) {
       $SPOStatus = "Document library never created"
       $NumberWarnings++ }
  
    $Status = "Pass"
    If ($NumberWarnings -eq 1)
       {
       $Status = "Warning"
    }
    If ($NumberWarnings -gt 1)
       {
       $Status = "Fail"
    } 

# If the group is team-Enabled, find the date of the last Teams conversation compliance record
If ($TeamsList.ContainsKey($G.ExternalDirectoryObjectId) -eq $True) {
      $TeamsEnabled = $True
      $TeamChatData = (Get-MailboxFolderStatistics -Identity $G.ExternalDirectoryObjectId -IncludeOldestAndNewestItems -FolderScope ConversationHistory)
   ForEach ($T in $TeamChatData) { # We might have one or two subfolders in Conversation History; find the one for Teams
   If ($T.FolderType -eq "TeamChat") {
      If ($T.ItemsInFolder -gt 0) {$LastItemAddedtoTeams = Get-Date ($T.NewestItemReceivedDate) -Format g}
      $NumberofChats = $T.ItemsInFolder
      If ($T.NewestItemReceivedDate -le $WarningEmailDate) {
            Write-Host "Team-enabled group" $G.DisplayName "has only" $T.ItemsInFolder "compliance record(s)" }
     }}      
}
# Generate a line for this group and store it in the report
    $ReportLine = [PSCustomObject][Ordered]@{
          GroupName           = $G.DisplayName
          ManagedBy           = $ManagedBy
          Members             = $G.GroupMemberCount
          ExternalGuests      = $G.GroupExternalMemberCount
          Description         = $G.Notes
          MailboxStatus       = $MailboxStatus
          TeamEnabled         = $TeamsEnabled
          LastChat            = $LastItemAddedtoTeams
          NumberChats         = $NumberofChats
          LastConversation    = $LastConversation
          NumberConversations = $NumberConversations
          SPOActivity         = $SPOActivity
          SPOStorageGB        = $SPOStorage
          SPOStatus           = $SPOStatus
          WhenCreated         = Get-Date ($G.WhenCreated) -Format g
          DaysOld             = $GroupAge
          NumberWarnings      = $NumberWarnings
          Status              = $Status}
   $Report.Add($ReportLine)   
#End of main loop
}

If ($TeamsCount -gt 0) { # We have some teams, so we can calculate a percentage of Team-enabled groups
    $PercentTeams = ($TeamsCount/$GroupsCount)
    $PercentTeams = ($PercentTeams).tostring("P") }
Else {
    $PercentTeams = "No teams found" }

# Create the HTML report
$htmlbody = $Report | ConvertTo-Html -Fragment
$htmltail = "<p>Report created for: " + $OrgName + "
             </p>
             <p>Number of groups scanned: " + $GroupsCount + "</p>" +
             "<p>Number of potentially obsolete groups (based on document library activity): " + $ObsoleteSPOGroups + "</p>" +
             "<p>Number of potentially obsolete groups (based on conversation activity): " + $ObsoleteEmailGroups + "<p>"+
             "<p>Number of Teams-enabled groups    : " + $TeamsCount + "</p>" +
             "<p>Percentage of Teams-enabled groups: " + $PercentTeams + "</body></html>" +
             "<p>-----------------------------------------------------------------------------------------------------------------------------"+
             "<p>Microsoft 365 Groups and Teams Activity Report <b>V4.5</b>"	
$htmlreport = $htmlhead + $htmlbody + $htmltail
$htmlreport | Out-File $ReportFile  -Encoding UTF8
$Report | Export-CSV -NoTypeInformation $CSVFile
$Report | Out-GridView
# Summary note
CLS
Write-Host " "
Write-Host "Results"
Write-Host "-------"
Write-Host "Number of Microsoft 365 Groups scanned                          :" $GroupsCount
Write-Host "Potentially obsolete groups (based on document library activity):" $ObsoleteSPOGroups
Write-Host "Potentially obsolete groups (based on conversation activity)    :" $ObsoleteEmailGroups
Write-Host "Number of Teams-enabled groups                                  :" $TeamsList.Count
Write-Host "Percentage of Teams-enabled groups                              :" $PercentTeams
Write-Host " "
Write-Host "Summary report in" $ReportFile "and CSV in" $CSVFile
