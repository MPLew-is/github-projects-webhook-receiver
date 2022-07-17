import Foundation

import BigInt


let keyLength_bits: Int = 256
let keyLength_bytes = keyLength_bits / 8

// Create the requested number of random bytes.
let key: Data = .init(
	(0 ..< keyLength_bytes).map { _ in
		UInt8.random(in: 0...UInt8.max)
	}
)

// Convert the bytes through `BitUInt` for base-36 encoding, then print.
let key_integer = BigUInt(key)
print(String(key_integer, radix: 36))
