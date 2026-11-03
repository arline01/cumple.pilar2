$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$rootPrefix = $root.TrimEnd('\') + '\'

$port = 50906

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$pageUrl = "http://127.0.0.1:$port/"
try {
    $listener.Start()
} catch [System.Net.HttpListenerException] {
    Write-Host "El servidor ya está en uso. Abriendo $pageUrl"
    Start-Process $pageUrl
    exit
}

Write-Host "Abriendo la página en $pageUrl"
Write-Host "Deja esta ventana abierta mientras usas la página. Ciérrala para detener el servidor."
Start-Process $pageUrl

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $relativePath = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart('/'))
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        $relativePath = 'cumpleaños pilar.html'
    }

    $filePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relativePath))
    if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $context.Response.StatusCode = 403
        $context.Response.Close()
        continue
    }

    if (-not [System.IO.File]::Exists($filePath)) {
        $context.Response.StatusCode = 404
        $context.Response.Close()
        continue
    }

    $contentTypes = @{
        '.html' = 'text/html; charset=utf-8'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.png'  = 'image/png'
        '.mp4'  = 'video/mp4'
        '.css'  = 'text/css; charset=utf-8'
        '.js'   = 'application/javascript; charset=utf-8'
    }
    $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
    if ($contentTypes.ContainsKey($extension)) {
        $context.Response.ContentType = $contentTypes[$extension]
    } else {
        $context.Response.ContentType = 'application/octet-stream'
    }

    $context.Response.Headers['Accept-Ranges'] = 'bytes'
    $fileStream = [System.IO.File]::OpenRead($filePath)
    $start = [long]0
    $end = $fileStream.Length - 1
    $rangeHeader = $context.Request.Headers['Range']
    if ($rangeHeader -and $rangeHeader -match '^bytes=(\d*)-(\d*)$') {
        if ($Matches[1]) {
            $start = [long]$Matches[1]
            if ($Matches[2]) {
                $end = [Math]::Min([long]$Matches[2], $fileStream.Length - 1)
            }
        } elseif ($Matches[2]) {
            $suffixLength = [long]$Matches[2]
            $start = [Math]::Max(0, $fileStream.Length - $suffixLength)
        }

        if ($start -ge $fileStream.Length -or $start -gt $end) {
            $context.Response.StatusCode = 416
            $context.Response.Headers['Content-Range'] = "bytes */$($fileStream.Length)"
            $context.Response.ContentLength64 = 0
            $fileStream.Dispose()
            $context.Response.Close()
            continue
        }

        $context.Response.StatusCode = 206
        $context.Response.Headers['Content-Range'] = "bytes $start-$end/$($fileStream.Length)"
    }

    $contentLength = $end - $start + 1
    $context.Response.ContentLength64 = $contentLength
    try {
        if ($context.Request.HttpMethod -ne 'HEAD') {
            $fileStream.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
            $buffer = New-Object byte[] 65536
            while ($contentLength -gt 0) {
                $bytesToRead = [int][Math]::Min($buffer.Length, $contentLength)
                $bytesRead = $fileStream.Read($buffer, 0, $bytesToRead)
                if ($bytesRead -eq 0) {
                    break
                }
                $context.Response.OutputStream.Write($buffer, 0, $bytesRead)
                $contentLength -= $bytesRead
            }
        }
    } catch [System.Net.HttpListenerException] {
        Write-Warning 'El navegador cerró una conexión antes de terminar la descarga.'
    } finally {
        $fileStream.Dispose()
        $context.Response.Close()
    }
}
