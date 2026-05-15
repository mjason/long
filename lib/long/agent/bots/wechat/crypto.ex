defmodule Long.Agent.Bots.Wechat.Crypto do
  @moduledoc """
  AES-128-ECB with PKCS7 padding — the encryption scheme iLink uses for
  CDN-hosted media (`novac2c.cdn.weixin.qq.com/c2c`). Both upload and
  download go through this; the key is a 16-byte value generated per
  message and shared with the recipient in plaintext over the bot API
  (this is a transport-encryption-at-rest layer, not end-to-end).
  """

  @block_size 16

  @doc """
  Encrypt with AES-128-ECB + PKCS7 padding. `key` must be exactly 16
  bytes.
  """
  @spec encrypt(binary(), binary()) :: binary()
  def encrypt(plaintext, key) when is_binary(plaintext) and byte_size(key) == @block_size do
    pad = @block_size - rem(byte_size(plaintext), @block_size)
    padded = plaintext <> :binary.copy(<<pad>>, pad)
    :crypto.crypto_one_time(:aes_128_ecb, key, padded, true)
  end

  @doc """
  Decrypt AES-128-ECB output and strip PKCS7 padding.
  """
  @spec decrypt(binary(), binary()) :: binary()
  def decrypt(ciphertext, key) when is_binary(ciphertext) and byte_size(key) == @block_size do
    decrypted = :crypto.crypto_one_time(:aes_128_ecb, key, ciphertext, false)
    pad = :binary.last(decrypted)
    binary_part(decrypted, 0, byte_size(decrypted) - pad)
  end

  @doc """
  Size of the AES-ECB ciphertext for a given plaintext byte size, with
  PKCS7 padding. Matches Python's `((len(raw) // 16) + 1) * 16`.
  """
  @spec ciphertext_size(non_neg_integer()) :: non_neg_integer()
  def ciphertext_size(plaintext_size) when is_integer(plaintext_size) and plaintext_size >= 0 do
    div(plaintext_size, @block_size) * @block_size + @block_size
  end

  @doc "Generate a fresh 16-byte random AES key."
  def random_key, do: :crypto.strong_rand_bytes(@block_size)
end
