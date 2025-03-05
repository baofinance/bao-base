import sys
import sha3

if len(sys.argv) != 2:
    print("Usage: python keccak.py <filename>")
    sys.exit(1)

filename = sys.argv[1]

try:
    with open(filename, 'rb') as f:
        file_data = f.read()
except FileNotFoundError:
    print(f"Error: File '{filename}' not found.")
    sys.exit(1)

hash_value = sha3.keccak_256(file_data).hexdigest()
print(hash_value)