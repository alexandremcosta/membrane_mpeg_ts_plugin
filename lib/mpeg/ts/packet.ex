defmodule MPEG.TS.Packet do
  @ts_packet_size 188
  @ts_header_size 4
  @ts_payload_size @ts_packet_size - @ts_header_size

  @type adaptation_t :: :payload | :adaptation | :adaptation_and_payload | :reserved

  @type scrambling_t :: :no | :even_key | :odd_key | :reserved

  @type pid_class_t :: :pat | :psi | :null_packet | :unsupported
  @type pid_t :: pos_integer()

  @type payload_t :: bitstring()
  @type t :: %__MODULE__{
          payload: payload_t(),
          is_unit_start: boolean(),
          pid: pid_t(),
          continuity_counter: binary(),
          scrambling: scrambling_t()
        }
  defstruct [:payload, :is_unit_start, :pid, :continuity_counter, :scrambling]

  @type parse_error_t ::
          :invalid_data | :invalid_packet | :unsupported_packet

  @spec parse(binary()) ::
          {:ok, t} | {:error, parse_error_t} | {:error, :not_enough_data, binary()}
  def parse(<<
        0x47::8,
        _transport_error_indicator::1,
        payload_unit_start_indicator::1,
        _transport_priority::1,
        pid::13,
        transport_scrambling_control::2,
        adaptation_field_control::2,
        continuity_counter::4,
        optional_fields::@ts_payload_size-binary
      >>) do
    with adaptation_field_id = parse_adaptation_field(adaptation_field_control),
         pid_class = parse_pid_class(pid),
         pusi = parse_pusi(payload_unit_start_indicator),
         scrambling = parse_scrambling_control(transport_scrambling_control),
         {:ok, data} <- parse_payload(optional_fields, adaptation_field_id, pid_class) do
      {:ok,
       %__MODULE__{
         is_unit_start: pusi,
         pid: pid,
         payload: data,
         scrambling: scrambling,
         continuity_counter: continuity_counter
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(data = <<0x47::8, _::binary>>) when byte_size(data) < @ts_packet_size,
    do: {:error, :not_enough_data, data}

  def parse(_data), do: {:error, :invalid_data}

  def packet_size(), do: @ts_packet_size

  @spec parse_many(binary()) :: [{:error, parse_error_t()} | {:ok, t}]
  def parse_many(data) do
    for <<packet::binary-@ts_packet_size <- data>>, do: parse(packet)
  end

  @spec parse_many!(binary()) :: [t]
  def parse_many!(data) do
    data
    |> parse_many()
    |> Enum.map(fn {:ok, x} -> x end)
  end

  @spec parse_valid(binary()) :: [t]
  def parse_valid(data) do
    data
    |> parse_many()
    |> Enum.filter(fn
      {:ok, _} -> true
      {:error, _} -> false
    end)
    |> Enum.map(fn {:ok, x} -> x end)
  end

  defp parse_adaptation_field(0b01), do: :payload
  defp parse_adaptation_field(0b10), do: :adaptation
  defp parse_adaptation_field(0b11), do: :adaptation_and_payload
  defp parse_adaptation_field(0b00), do: :reserved

  defp parse_scrambling_control(0b00), do: :no
  defp parse_scrambling_control(0b01), do: :reserved
  defp parse_scrambling_control(0b10), do: :even_key
  defp parse_scrambling_control(0b11), do: :odd_key

  defp parse_pid_class(0x0000), do: :pat
  defp parse_pid_class(id) when id in 0x0020..0x1FFA or id in 0x1FFC..0x1FFE, do: :psi
  defp parse_pid_class(0x1FFF), do: :null_packet
  defp parse_pid_class(_), do: :unsupported

  defp parse_pusi(0b1), do: true
  defp parse_pusi(0b0), do: false

  @spec parse_payload(binary(), adaptation_t(), pid_class_t()) ::
          {:ok, bitstring()} | {:error, parse_error_t()}
  defp parse_payload(_, :adaptation, _), do: {:ok, <<>>}
  defp parse_payload(_, :reserved, _), do: {:error, :unsupported_packet}
  defp parse_payload(_, :payload, :null_packet), do: {:ok, <<>>}

  defp parse_payload(
         <<
           adaptation_field_length::8,
           _adaptation_field::binary-size(adaptation_field_length),
           payload::bitstring
         >>,
         :adaptation_and_payload,
         pid
       ),
       do: parse_payload(payload, :payload, pid)

  defp parse_payload(payload, :payload, :psi), do: {:ok, payload}
  defp parse_payload(payload, :payload, :pat), do: {:ok, payload}

  # TODO: I got packets with adaptation_and_payload that do not conform to the
  # format above and hence create errors.
  # defp parse_payload(_, :payload, _), do: {:error, :unsupported_packet}
  defp parse_payload(_, _, _), do: {:error, :unsupported_packet}
end
