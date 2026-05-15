defmodule Sonnet.OIDCTokenVerifier do
  @moduledoc false

  @well_known_path "/.well-known/openid-configuration"
  @supported_algs ["RS256"]

  def verify_id_token(token) when is_binary(token) do
    with :ok <- validate_jwt_shape(token),
         {:ok, header} <- decode_header(token),
         {:ok, config} <- oidc_config(),
         {:ok, jwks} <- load_jwks(config),
         {:ok, key} <- key_for_header(jwks, header),
         {:ok, claims} <- verify_signature(token, key),
         :ok <- validate_claims(claims, config) do
      {:ok, claims}
    end
  end

  def verify_id_token(_token), do: {:error, :malformed_token}

  defp validate_jwt_shape(token) do
    case String.split(token, ".") do
      [_header, _payload, _signature] -> :ok
      _ -> {:error, :malformed_token}
    end
  end

  defp decode_header(token) do
    token
    |> String.split(".")
    |> List.first()
    |> Base.url_decode64(padding: false)
    |> case do
      {:ok, json} -> Jason.decode(json)
      :error -> {:error, :malformed_token}
    end
    |> case do
      {:ok, %{} = header} -> {:ok, header}
      _ -> {:error, :malformed_token}
    end
  end

  defp oidc_config do
    mobile_config = Application.get_env(:sonnet, :mobile_oidc, [])
    issuer = Keyword.get(mobile_config, :issuer) || configured_issuer()
    client_id = Keyword.get(mobile_config, :client_id) || configured_client_id()

    cond do
      !is_binary(issuer) or issuer == "" -> {:error, :invalid_issuer}
      !is_binary(client_id) or client_id == "" -> {:error, :invalid_audience}
      true -> {:ok, %{issuer: issuer, client_id: client_id, mobile_config: mobile_config}}
    end
  end

  defp configured_issuer do
    :ueberauth_oidcc
    |> Application.get_env(:issuers, [])
    |> Enum.find_value(fn
      %{name: :oidcc_issuer, issuer: issuer} -> issuer
      _ -> nil
    end)
  end

  defp configured_client_id do
    :ueberauth_oidcc
    |> Application.get_env(:providers, [])
    |> Keyword.get(:oidc, [])
    |> Keyword.get(:client_id)
  end

  defp load_jwks(%{mobile_config: mobile_config, issuer: issuer}) do
    cond do
      jwks = Keyword.get(mobile_config, :jwks) ->
        {:ok, jwks}

      jwks_uri = Keyword.get(mobile_config, :jwks_uri) ->
        fetch_json(jwks_uri)

      true ->
        discovery_url = String.trim_trailing(issuer, "/") <> @well_known_path

        with {:ok, %{"jwks_uri" => jwks_uri}} <- fetch_json(discovery_url) do
          fetch_json(jwks_uri)
        else
          _ -> {:error, :invalid_signature}
        end
    end
  end

  defp fetch_json(url) do
    case Req.get(url) do
      {:ok, %{status: status, body: %{} = body}} when status in 200..299 -> {:ok, body}
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  defp key_for_header(%{"keys" => keys}, %{"kid" => kid, "alg" => alg})
       when is_list(keys) and alg in @supported_algs do
    keys
    |> Enum.find(fn key -> key["kid"] == kid end)
    |> case do
      nil -> {:error, :invalid_signature}
      key -> {:ok, JOSE.JWK.from_map(key)}
    end
  end

  defp key_for_header(_jwks, _header), do: {:error, :invalid_signature}

  defp verify_signature(token, key) do
    case JOSE.JWT.verify_strict(key, @supported_algs, token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :malformed_token}
  end

  defp validate_claims(claims, %{issuer: issuer, client_id: client_id}) do
    cond do
      claims["iss"] != issuer ->
        {:error, :invalid_issuer}

      !valid_audience?(claims["aud"], client_id) ->
        {:error, :invalid_audience}

      expired?(claims["exp"]) ->
        {:error, :expired_token}

      !is_binary(claims["sub"]) or String.trim(claims["sub"]) == "" ->
        {:error, :missing_subject}

      true ->
        :ok
    end
  end

  defp valid_audience?(audience, client_id) when is_binary(audience), do: audience == client_id
  defp valid_audience?(audience, client_id) when is_list(audience), do: client_id in audience
  defp valid_audience?(_audience, _client_id), do: false

  defp expired?(exp) when is_integer(exp), do: exp <= System.system_time(:second)
  defp expired?(_exp), do: true
end
