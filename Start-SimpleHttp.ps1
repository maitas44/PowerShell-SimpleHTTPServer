param(
    [int]$Port = 8080, # Default to 8080, use 80 if needed (requires Admin)
    [string]$DirectoryToServe = $PWD.Path
)

# Port 80 (and listening on '+') requires running PowerShell as Administrator
if (($Port -eq 80 -or $PSBoundParameters.ContainsKey('Prefix') -and $Prefix -like 'http://+*') -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Port 80 or listening on 'http://+' requires running PowerShell as Administrator."
    exit 1
}

if (-not (Test-Path $DirectoryToServe -PathType Container)) {
     Write-Error "Directory not found: $DirectoryToServe"
    exit 1
}

$listener = New-Object System.Net.HttpListener
# Listen on all network interfaces for the specified port (requires Admin for '+')
$prefixToAdd = "http://+:$Port/"
try {
     $listener.Prefixes.Add($prefixToAdd)
} catch {
     Write-Error "Failed to add prefix '$prefixToAdd'. Ensure you are running as Administrator. Error: $_"
     exit 1
}


Write-Host "Starting HTTP server on port $Port, serving '$DirectoryToServe'..."
Write-Host "Access via http://<your_ip_address>:$Port or http://localhost:$Port"
Write-Host "Press Ctrl+C to stop."

try {
    $listener.Start()
    while ($listener.IsListening) {
        # Wait for a connection
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $localPath = $request.Url.LocalPath
        # Simple security: prevent path traversal and decode URLencoded paths
        $localPathDecoded = [System.Web.HttpUtility]::UrlDecode($localPath) # Decode %20 etc.
        if ($localPathDecoded -match '\\|:\.\.') { # Disallow backslashes or .. after decoding
             $response.StatusCode = 400 # Bad Request
             Write-Warning "Blocked potentially malicious path: $localPath"
             $response.Close()
             continue
        }

        # Construct the full path to the requested item
        # Remove leading '/' and replace other '/' with '\' for Windows path
        $fileSystemPathPart = $localPathDecoded.Substring(1).Replace('/','\')
        $filePath = Join-Path -Path $DirectoryToServe -ChildPath $fileSystemPathPart

        Write-Verbose "Request: $($request.Url) -> FileSystem Path: $filePath"

        # --- START: Logic to serve file, list directory, or return 404 ---
        if (Test-Path $filePath -PathType Leaf) {
            # It's a file, serve it
            try {
                $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentLength64 = $fileBytes.Length
                # Basic MIME type guessing (add more as needed)
                $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
                switch ($ext) {
                    ".html" { $response.ContentType = "text/html; charset=utf-8" }
                    ".htm"  { $response.ContentType = "text/html; charset=utf-8" }
                    ".txt"  { $response.ContentType = "text/plain; charset=utf-8" }
                    ".css"  { $response.ContentType = "text/css" }
                    ".js"   { $response.ContentType = "application/javascript" }
                    ".json" { $response.ContentType = "application/json" }
                    ".xml"  { $response.ContentType = "application/xml" }
                    ".png"  { $response.ContentType = "image/png" }
                    ".jpg"  { $response.ContentType = "image/jpeg" }
                    ".jpeg" { $response.ContentType = "image/jpeg" }
                    ".gif"  { $response.ContentType = "image/gif" }
                    ".ico"  { $response.ContentType = "image/x-icon" }
                    ".svg"  { $response.ContentType = "image/svg+xml" }
                    ".zip"  { $response.ContentType = "application/zip"}
                    ".pdf"  { $response.ContentType = "application/pdf"}
                    # Add more common types as needed
                    default { $response.ContentType = "application/octet-stream" } # Default binary
                }

                $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                $response.StatusCode = 200 # OK
                Write-Host "Served file: $filePath"
            } catch {
                 Write-Warning "Error reading file '$filePath': $_"
                 $response.StatusCode = 500 # Internal Server Error
            }
        }
        elseif (Test-Path $filePath -PathType Container) {
            # It's a directory, generate a listing
            try {
                $listingHtml = "<html><head><title>Index of $($request.Url.LocalPath)</title><style>body{font-family:sans-serif;} ul{list-style:none; padding-left: 1em;} li{ margin-bottom: 0.3em;}</style></head><body><h1>Index of $($request.Url.LocalPath)</h1><hr/><ul>"
                # Add link to parent directory if not root
                if ($request.Url.LocalPath -ne '/') {
                     $parentPath = ($request.Url.LocalPath.TrimEnd('/') -replace '/[^/]+$') # Go up one level
                     if ($parentPath -eq "") {$parentPath = "/"} # Handle going up from first level dir
                     $listingHtml += "<li><a href=""$($parentPath)"">[Parent Directory]</a></li>"
                }

                # List Directories First
                 Get-ChildItem -Path $filePath -Directory | Sort-Object Name | ForEach-Object {
                     $itemName = $_.Name
                     $encodedItemName = [System.Web.HttpUtility]::UrlEncode($itemName) # Encode spaces etc.
                     $itemPath = "$($request.Url.LocalPath.TrimEnd('/'))/$encodedItemName" # Construct URL path
                     $listingHtml += "<li>&#x1F4C1; <a href=""$itemPath/"">$itemName/</a></li>" # Folder icon + link with /
                 }
                 # List Files Second
                 Get-ChildItem -Path $filePath -File | Sort-Object Name | ForEach-Object {
                     $itemName = $_.Name
                     $encodedItemName = [System.Web.HttpUtility]::UrlEncode($itemName)
                     $itemPath = "$($request.Url.LocalPath.TrimEnd('/'))/$encodedItemName"
                     $listingHtml += "<li>&#x1F4C4; <a href=""$itemPath"">$itemName</a></li>" # File icon + link
                 }

                $listingHtml += "</ul><hr/></body></html>"

                $listingBytes = [System.Text.Encoding]::UTF8.GetBytes($listingHtml)
                $response.ContentType = "text/html; charset=utf-8"
                $response.ContentLength64 = $listingBytes.Length
                $response.OutputStream.Write($listingBytes, 0, $listingBytes.Length)
                $response.StatusCode = 200 # OK
                Write-Host "Served directory listing for: $filePath"
            } catch {
                 Write-Warning "Error generating directory listing for '$filePath': $_"
                 $response.StatusCode = 500 # Internal Server Error
            }
        }
        else {
            # It's not a file and not a directory - truly not found
            $response.StatusCode = 404 # Not Found
            $errorMessage = "<html><body style=""font-family:sans-serif""><h1>404 Not Found</h1><p>File or directory not found: $($request.Url.LocalPath)</p></body></html>"
            $errorBytes = [System.Text.Encoding]::UTF8.GetBytes($errorMessage)
            $response.ContentType = "text/html; charset=utf-8"
            $response.ContentLength64 = $errorBytes.Length
            $response.OutputStream.Write($errorBytes, 0, $errorBytes.Length)
            Write-Host "404 Not Found for request: $($request.Url.LocalPath) (Path: $filePath)"
        }
        # --- END: Logic block ---

        # Close the response stream for this request
        $response.OutputStream.Flush() # Ensure data is sent before closing
        $response.Close()
    } # End while ($listener.IsListening)
}
catch [System.Net.HttpListenerException] {
    if ($_.Exception.ErrorCode -eq 5) { # ErrorCode 5 is Access Denied
        Write-Error "Access Denied. Port $Port might be in use or requires Administrator privileges. $_"
    } else {
        Write-Error "An HttpListener error occurred: $_"
    }
}
catch {
    Write-Error "An unexpected error occurred: $_"
}
finally {
    if ($listener -ne $null) {
        if ($listener.IsListening) {
            Write-Host "Stopping HTTP server..."
            $listener.Stop()
        }
        $listener.Close() # Release the listener object
    }
}
