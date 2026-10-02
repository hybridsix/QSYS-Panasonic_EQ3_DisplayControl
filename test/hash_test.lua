local T = require("helpers")
local Hash = require("hash")

-- Expected digests were generated with Node's crypto module.
local VECTORS = {
  { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "900150983cd24fb0d6963f7d28e17f72" },
  { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "d41d8cd98f00b204e9800998ecf8427e" },
  { string.rep("a", 100), "2816597888e4a0d3a36b82b83316ab32680eb8f00f8cd3b904d681246d285a0e", "36a92cc94a9e0fa21f625f8bfb007adf" },
  { "admin1:secret:23181e1e", "aade6e0a88ae17960064dd516cd835af889f2882072741cf08b89d900f13f41f", "980a8884e5b88829f9df782f2cdde066" },
  -- Padding boundaries: 55 bytes fits one block, 56 needs two.
  { string.rep("b", 55), "eb2c86e932179f4ba13fe8715a26124b77d6bad290b9b4c1cc140cf633300c19", "73979428bc0de15c39d14ae331b35295" },
  { string.rep("b", 56), "a5fc6e203a4c2b657d0d153885932414b2ffc6a93f0f8bf8b3183315e5a7212c", "b9d955696c7654cd20086bec31670b11" },
}

for i, v in ipairs(VECTORS) do
  T.test("SHA-256 vector " .. i, function()
    T.eq(Hash.sha256(v[1]), v[2])
  end)
  T.test("MD5 vector " .. i, function()
    T.eq(Hash.md5(v[1]), v[3])
  end)
end

T.test("digests have the documented lengths", function()
  T.eq(#Hash.sha256("x"), 64)
  T.eq(#Hash.md5("x"), 32)
end)

return T.finish()
