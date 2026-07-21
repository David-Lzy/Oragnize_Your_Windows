@{
    # Use a local, healthy NTFS volume. Passing F:\ produces
    # F:\BrowserCache\... and F:\DevCache\...
    DestinationRoot = 'F:\'

    Browsers = @('Chrome', 'Brave', 'Edge')
    IncludeDeveloper = $true

    # $false copies existing cache content before replacing the source with a
    # directory junction. $true clears existing disposable cache content.
    DiscardExisting = $false
}
