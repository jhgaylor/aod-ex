defmodule AgentOnDemand.PropertyTest do
  @moduledoc """
  Property-based tests covering the highest-leverage pure modules:
  Crypto round-trip, Provisioning shell-quoting + token redaction, SSE
  parser. Runs StreamData generators to catch edge cases that example-
  based tests miss.

  These are a substitute for proper mutation testing — Elixir's mutation
  tools (Muzak) are unmaintained, so we instead cast a wide net of
  inputs at the most regression-prone surfaces and let StreamData find
  bugs by exhaustion.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias AgentOnDemand.Crypto
  alias AgentOnDemand.Conversations.Provisioning
  alias AodCli.Sse

  describe "Crypto round-trip" do
    property "every plaintext decrypts back to itself" do
      check all plaintext <- StreamData.binary(min_length: 0, max_length: 4096) do
        ct = Crypto.encrypt(plaintext)
        assert {:ok, ^plaintext} = Crypto.decrypt(ct)
      end
    end

    property "two encryptions of the same plaintext have different ciphertext" do
      check all plaintext <- StreamData.binary(min_length: 1, max_length: 64) do
        a = Crypto.encrypt(plaintext)
        b = Crypto.encrypt(plaintext)
        assert a != b
      end
    end

    property "tampering with body bytes makes decrypt fail" do
      check all plaintext <- StreamData.binary(min_length: 1, max_length: 64) do
        ct = Crypto.encrypt(plaintext)
        <<head::binary-12, tag::binary-16, body::binary>> = ct
        flipped = :crypto.exor(body, :binary.copy(<<1>>, byte_size(body)))
        assert :error = Crypto.decrypt(head <> tag <> flipped)
      end
    end
  end

  describe "Provisioning.shell_quote" do
    property "round-trips through bash unchanged for printable ASCII" do
      # Skip control characters that bash interprets specially.
      printable = StreamData.string(:printable, min_length: 0, max_length: 64)

      check all s <- printable do
        quoted = Provisioning.shell_quote(s)
        # bash -lc 'echo <quoted>' should print exactly s + a newline
        {output, 0} = System.cmd("bash", ["-lc", "echo " <> quoted])
        assert String.trim_trailing(output, "\n") == s
      end
    end

    property "always wraps in single quotes" do
      check all s <- StreamData.string(:ascii, min_length: 0, max_length: 32) do
        quoted = Provisioning.shell_quote(s)
        assert String.starts_with?(quoted, "'")
        assert String.ends_with?(quoted, "'")
      end
    end
  end

  describe "Provisioning.scrub_token" do
    property "never leaves the literal token in output" do
      token_chars =
        StreamData.string(:alphanumeric, min_length: 8, max_length: 64)
        |> StreamData.filter(&(byte_size(&1) > 0))

      surroundings =
        StreamData.string(:printable, min_length: 0, max_length: 32)

      check all token <- token_chars,
                prefix <- surroundings,
                suffix <- surroundings do
        input = "#{prefix}https://x-access-token:#{token}@github.com/foo/bar#{suffix}"
        scrubbed = Provisioning.scrub_token(input)
        refute scrubbed =~ token
        assert scrubbed =~ "x-access-token:***@"
      end
    end

    property "is a no-op on inputs without an x-access-token URL" do
      check all s <- StreamData.string(:printable, min_length: 0, max_length: 200),
                not String.contains?(s, "x-access-token:") do
        assert Provisioning.scrub_token(s) == s
      end
    end
  end

  describe "Provisioning.inject_token" do
    property "non-https URLs come back unchanged" do
      check all url <- StreamData.member_of(["git@github.com:foo/bar", "ssh://x", "http://y"]),
                token <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32) do
        assert Provisioning.inject_token(url, "K", %{"K" => token}) == url
      end
    end

    property "https URLs get the token inlined exactly once" do
      check all path <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
                token <- StreamData.string(:alphanumeric, min_length: 8, max_length: 64) do
        url = "https://github.com/#{path}"
        out = Provisioning.inject_token(url, "K", %{"K" => token})
        assert out == "https://x-access-token:#{token}@github.com/#{path}"
        # exactly one @ between the token and host
        assert length(String.split(out, "x-access-token:")) == 2
      end
    end
  end

  describe "SSE parser" do
    property "any well-formed event chunk parses without crashing" do
      id_gen = StreamData.integer(0..1_000_000)
      event_gen = StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
      data_gen = StreamData.string(:printable, min_length: 0, max_length: 200)

      check all id <- id_gen,
                event <- event_gen,
                data <- data_gen,
                # SSE forbids \n in data fields; strip
                data = String.replace(data, "\n", " ") do
        chunk = "id: #{id}\nevent: #{event}\ndata: #{data}\n\n"
        assert {[parsed], ""} = Sse.feed(chunk)
        assert parsed.id == id
        assert parsed.event == event
      end
    end

    property "splitting an event across feeds still recovers it" do
      check all id <- StreamData.integer(0..1000),
                # split anywhere INSIDE the event (before the \n\n terminator)
                split_at <- StreamData.integer(1..28) do
        full = "id: #{id}\nevent: x\ndata: {}\n\n"
        # Pick a split that's strictly before the terminator so the first
        # call is guaranteed to leave leftover.
        cut = min(split_at, byte_size(full) - 3)
        first = binary_part(full, 0, cut)
        rest = binary_part(full, cut, byte_size(full) - cut)

        {events1, leftover} = Sse.feed(first)
        # No complete event in the first chunk
        assert events1 == []

        {events2, _} = Sse.feed(leftover <> rest)
        assert [event] = events2
        assert event.id == id
      end
    end
  end
end
