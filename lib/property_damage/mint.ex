defmodule PropertyDamage.Mint do
  @moduledoc false
  # Internal module - users create markers via `PropertyDamage.mint_per_run/1`.
  #
  # A Mint marker (DR-034) marks a command field as a client-minted, run-scoped
  # value: minted at execution rather than fixed at generation, so the plan
  # stays a pure function of the effective seed while the value is unique per
  # run (a request UUID / idempotency key sent to a non-resettable SUT).
  #
  # Contrast with %Placeholder{} (external()): a placeholder captures a value the
  # SUT *returns*; a Mint mints a value the client *sends*. A Mint therefore has
  # no producer/capture side and never enters the placeholder registry.
  #
  # Lifecycle:
  # 1. `mint_per_run(kind)` returns an unreified marker (position/path nil).
  # 2. Generation reifies it with its `(position, path)` coordinates (DR-036),
  #    baked into the command struct so the value is stable under shrinking.
  # 3. The executor's resolution pass (and PlaceholderRegistry.resolve_data/2 for
  #    the Differential/LoadTest engines) derives the concrete value from
  #    `(run_nonce, mint_epoch, position, path, kind)`.

  alias PropertyDamage.Sequence.Position

  @typedoc """
  A mint kind. High entropy is load-bearing: provenance classification (DR-034)
  recognizes minted echoes in event fields by value, which is only sound when
  accidental equality is negligible.

  - `:uuid` - 16 derived bytes as an RFC 4122 (version 4) UUID string.
  - `{:hex, n}` - the first `n` lowercase hex characters of the digest.
  - `{module, function}` - escape hatch; `function` receives the derived bytes
    (a binary) and returns the value. NOT an anonymous function: markers persist
    inside plans/traces and anonymous funs do not survive `binary_to_term`.
  """
  @type kind :: :uuid | {:hex, pos_integer()} | {module(), atom()}

  @type t :: %__MODULE__{
          kind: kind(),
          position: Position.t() | nil,
          path: [atom() | non_neg_integer()] | nil
        }

  defstruct [:kind, :position, :path]

  @doc "An unreified marker for `kind` (coordinates filled at generation)."
  @spec new(kind()) :: t()
  def new(kind) do
    validate_kind!(kind)
    %__MODULE__{kind: kind}
  end

  defp validate_kind!(:uuid), do: :ok
  defp validate_kind!({:hex, n}) when is_integer(n) and n > 0, do: :ok
  defp validate_kind!({mod, fun}) when is_atom(mod) and is_atom(fun), do: :ok

  defp validate_kind!(other) do
    raise ArgumentError,
          "invalid mint_per_run kind: #{inspect(other)}. " <>
            "Expected :uuid, {:hex, n}, or {module, function} " <>
            "(anonymous functions are not allowed - markers must survive persistence)."
  end

  @doc "Reify a marker with its generation coordinates (DR-036)."
  @spec reify(t(), Position.t(), [atom() | non_neg_integer()]) :: t()
  def reify(%__MODULE__{} = m, position, path), do: %{m | position: position, path: path}

  @doc "Whether a value is a mint marker."
  @spec marker?(term()) :: boolean()
  def marker?(%__MODULE__{}), do: true
  def marker?(_), do: false

  @doc """
  Resolve a marker to its concrete value for `(run_nonce, mint_epoch)` (DR-034).

  A pure function of `(run_nonce, mint_epoch, position, path, kind)` via SHA-256,
  then a kind-specific formatter. Never `UUID.uuid4/0`, `:rand`, or wall-clock.
  """
  @spec resolve(t(), non_neg_integer() | nil, non_neg_integer()) :: term()
  def resolve(%__MODULE__{kind: kind, position: position, path: path}, run_nonce, mint_epoch) do
    bytes =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({run_nonce, mint_epoch, position, path, kind}, minor_version: 2)
      )

    format(kind, bytes)
  end

  defp format(:uuid, <<a::32, b::16, c::16, d::16, e::48, _rest::binary>>) do
    # Set RFC 4122 version (4) and variant (10xx) bits.
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp format({:hex, n}, bytes) do
    bytes |> Base.encode16(case: :lower) |> String.slice(0, n)
  end

  defp format({module, function}, bytes) do
    apply(module, function, [bytes])
  end
end
