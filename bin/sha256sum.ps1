# hash-stdin.ps1
# Read all content from stdin
$content = [System.Console]::In.ReadToEnd()

# Convert the string to a byte array
$bytes = [System.Text.Encoding]::UTF8.GetBytes($content)

# Create a memory stream from the bytes
$stream = [System.IO.MemoryStream]::new($bytes)

# Calculate the SHA256 hash
$hash = Get-FileHash -InputStream $stream -Algorithm SHA256

# Output just the hash in lowercase
$hash.Hash.ToLower()

# Clean up
$stream.Dispose()