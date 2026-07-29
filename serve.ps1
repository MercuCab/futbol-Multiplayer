# Mini servidor HTTP estático (sin Node/Python) para probar el juego en el celular por WiFi.
$root = "C:\Users\Lalo\OneDrive\Desktop\futbol-multiplayer"
$port = 8080

$mime = @{
  ".html" = "text/html; charset=utf-8"
  ".js"   = "application/javascript"
  ".css"  = "text/css"
  ".json" = "application/json"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".svg"  = "image/svg+xml"
  ".webmanifest" = "application/manifest+json"
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
$listener.Start()
Write-Host "Sirviendo $root en el puerto $port (Ctrl+C para detener)"

while ($true) {
  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $requestLine = $reader.ReadLine()
    while ($reader.Peek() -ge 0 -and $reader.ReadLine() -ne "") {} # descartar headers

    if ($requestLine -match '^(GET|HEAD)\s+([^\s]+)\s+HTTP') {
      $path = $matches[2]
      if ($path -eq "/") { $path = "/milestone1-mobile-touch.html" }
      $path = [System.Uri]::UnescapeDataString($path.Split("?")[0])
      $filePath = Join-Path $root ($path.TrimStart("/"))
      $filePath = [System.IO.Path]::GetFullPath($filePath)

      if ($filePath.StartsWith($root) -and (Test-Path $filePath -PathType Leaf)) {
        $ext = [System.IO.Path]::GetExtension($filePath)
        $contentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $header = "HTTP/1.1 200 OK`r`nContent-Type: $contentType`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($bytes, 0, $bytes.Length)
      } else {
        $body = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $path")
        $header = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($body, 0, $body.Length)
      }
    }
  } catch {
    Write-Host "Error: $_"
  } finally {
    $client.Close()
  }
}
