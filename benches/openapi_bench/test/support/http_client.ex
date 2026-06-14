defmodule OpenapiBench.HttpClient do
  @moduledoc """
  Minimal `:httpc`-based JSON client for the smoke tests (the generated adapter
  uses its own HTTP path). Returns `{status, decoded_body}`.
  """

  def request(method, url, body \\ nil) do
    headers = [{~c"content-type", ~c"application/json"}]

    request =
      case method do
        :get -> {String.to_charlist(url), headers}
        _ -> {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body || %{})}
      end

    {:ok, {{_, status, _}, _resp_headers, resp_body}} =
      :httpc.request(method, request, [], body_format: :binary)

    {status, decode(resp_body)}
  end

  defp decode(""), do: nil
  defp decode(body), do: Jason.decode!(body)
end
