defmodule Sonnet.OIDCTokenVerifier do
  @moduledoc false

  alias Sonnet.MobileOIDC

  def verify_id_token(token) when is_binary(token) do
    with :ok <- validate_jwt_shape(token),
         {:ok, client_context} <- MobileOIDC.client_context(),
         {:ok, claims} <- Oidcc.Token.validate_id_token(token, client_context, :any),
         :ok <- validate_claims(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  def verify_id_token(_token), do: {:error, :malformed_token}

  defp validate_jwt_shape(token) do
    case String.split(token, ".") do
      [_header, _payload, _signature] -> :ok
      _ -> {:error, :malformed_token}
    end
  end

  defp validate_claims(%{"sub" => subject}) when is_binary(subject) do
    if String.trim(subject) == "", do: {:error, :missing_subject}, else: :ok
  end

  defp validate_claims(_claims), do: {:error, :missing_subject}

  defp normalize_error(:token_expired), do: :expired_token
  defp normalize_error(:no_matching_key), do: :invalid_signature
  defp normalize_error(:malformed_token), do: :malformed_token
  defp normalize_error(:invalid_audience), do: :invalid_audience
  defp normalize_error(:missing_subject), do: :missing_subject

  defp normalize_error({:missing_claim, {"aud", _expected}, _claims}), do: :invalid_audience
  defp normalize_error({:missing_claim, {"iss", _expected}, _claims}), do: :invalid_issuer
  defp normalize_error({:missing_claim, "sub", _claims}), do: :missing_subject
  defp normalize_error({:missing_claim, "exp", _claims}), do: :expired_token
  defp normalize_error(_reason), do: :invalid_token
end
