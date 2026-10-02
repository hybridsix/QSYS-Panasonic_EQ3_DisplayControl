-- SHA-256 and MD5 in pure Lua (hex digests).
--
-- Q-SYS provides no hashing library, and Panasonic command protect needs one.
-- Both algorithms work on 32-bit words and mask every result with MASK, so
-- they give the same answer whether Lua integers are 32 or 64 bits wide.
-- Only the digest of the authentication string is ever produced here; nothing
-- in this module logs or stores its input.
local Hash = {}

local MASK = 0xFFFFFFFF

local function rotr(x, n)
  return ((x >> n) | (x << (32 - n))) & MASK
end

local function rotl(x, n)
  return ((x << n) | (x >> (32 - n))) & MASK
end

-- Appends the 0x80 marker, zero padding and the 64-bit bit-length.
local function pad(message, bigEndian)
  local length = #message
  local zeros = (55 - length) % 64
  local bits = length * 8
  local tail = {}
  for i = 0, 7 do
    local shift = bigEndian and (7 - i) * 8 or i * 8
    tail[#tail + 1] = string.char((bits >> shift) & 0xFF)
  end
  return message .. "\128" .. string.rep("\0", zeros) .. table.concat(tail)
end

local function hexWord(word, bigEndian)
  local out = {}
  for i = 0, 3 do
    local shift = bigEndian and (3 - i) * 8 or i * 8
    out[#out + 1] = string.format("%02x", (word >> shift) & 0xFF)
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- SHA-256
-- ---------------------------------------------------------------------------
local SHA_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

function Hash.sha256(message)
  local data = pad(tostring(message), true)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local w = {}

  for block = 1, #data, 64 do
    for i = 1, 16 do
      local b1, b2, b3, b4 = data:byte(block + (i - 1) * 4, block + (i - 1) * 4 + 3)
      w[i] = ((b1 << 24) | (b2 << 16) | (b3 << 8) | b4) & MASK
    end
    for i = 17, 64 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = rotr(x, 7) ~ rotr(x, 18) ~ (x >> 3)
      local s1 = rotr(y, 17) ~ rotr(y, 19) ~ (y >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & MASK
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
      local ch = (e & f) ~ ((~e) & g)
      local t1 = (h + S1 + ch + SHA_K[i] + w[i]) & MASK
      local S0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local t2 = (S0 + maj) & MASK
      h, g, f = g, f, e
      e = (d + t1) & MASK
      d, c, b = c, b, a
      a = (t1 + t2) & MASK
    end

    h0, h1, h2, h3 = (h0 + a) & MASK, (h1 + b) & MASK, (h2 + c) & MASK, (h3 + d) & MASK
    h4, h5, h6, h7 = (h4 + e) & MASK, (h5 + f) & MASK, (h6 + g) & MASK, (h7 + h) & MASK
  end

  local out = {}
  for _, word in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do out[#out + 1] = hexWord(word, true) end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- MD5 (legacy; offered because the display can announce it)
-- ---------------------------------------------------------------------------
local MD5_K = {
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local MD5_S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

function Hash.md5(message)
  local data = pad(tostring(message), false)
  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  local m = {}

  for block = 1, #data, 64 do
    for i = 0, 15 do
      local b1, b2, b3, b4 = data:byte(block + i * 4, block + i * 4 + 3)
      m[i] = ((b4 << 24) | (b3 << 16) | (b2 << 8) | b1) & MASK
    end

    local a, b, c, d = a0, b0, c0, d0
    for i = 0, 63 do
      local f, g
      if i < 16 then
        f = (b & c) | ((~b) & d)
        g = i
      elseif i < 32 then
        f = (d & b) | ((~d) & c)
        g = (5 * i + 1) % 16
      elseif i < 48 then
        f = b ~ c ~ d
        g = (3 * i + 5) % 16
      else
        f = c ~ (b | ((~d) & MASK))
        g = (7 * i) % 16
      end
      f = (f + a + MD5_K[i + 1] + m[g]) & MASK
      a = d
      d = c
      c = b
      b = (b + rotl(f & MASK, MD5_S[i + 1])) & MASK
    end

    a0, b0, c0, d0 = (a0 + a) & MASK, (b0 + b) & MASK, (c0 + c) & MASK, (d0 + d) & MASK
  end

  local out = {}
  for _, word in ipairs({ a0, b0, c0, d0 }) do out[#out + 1] = hexWord(word, false) end
  return table.concat(out)
end

return Hash
