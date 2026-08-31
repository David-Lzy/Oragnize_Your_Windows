@{
    # Use a local, healthy NTFS volume. Passing F:\ produces
    # F:\BrowserCache\... and F:\DevCache\...
    DestinationRoot = 'F:\'

    Browsers = @('Chrome', 'ChromeBeta', 'Brave', 'Edge')
    IncludeDeveloper = $true

    # Browser profile/runtime caches and extension package caches are excluded
    # by default because they participate in startup and session restore.
    IncludeBrowserRuntimeCaches = $false

    # Keep this false. Turning it on only bypasses the confirmed-SSD guard when
    # browser runtime caches were also explicitly requested.
    AllowSlowOrUnknownBrowserDestination = $false

    # $false copies existing cache content before replacing the source with a
    # directory junction. $true clears existing disposable cache content.
    DiscardExisting = $false
}
