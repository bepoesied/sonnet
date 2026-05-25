defmodule Sonnet.MobileOIDC do
  @moduledoc false

  @issuer_name :oidcc_issuer
  @scopes ["openid", "profile"]

  def discovery do
    with {:ok, client_context} <- client_context() do
      provider = client_context.provider_configuration

      {:ok,
       %{
         issuer: provider.issuer,
         client_id: client_context.client_id,
         authorization_endpoint: provider.authorization_endpoint,
         token_endpoint: undefined_to_nil(provider.token_endpoint),
         end_session_endpoint: undefined_to_nil(provider.end_session_endpoint),
         scopes: scopes(),
         response_type: "code",
         code_challenge_methods_supported:
           undefined_to_nil(provider.code_challenge_methods_supported)
       }}
    end
  end

  def client_context do
    mobile_config = Application.get_env(:sonnet, :mobile_oidc, [])

    case Keyword.get(mobile_config, :client_context) do
      %Oidcc.ClientContext{} = client_context ->
        {:ok, client_context}

      nil ->
        client_context_from_config(mobile_config)
    end
  end

  def scopes do
    @scopes
  end

  defp client_context_from_config(mobile_config) do
    client_id = Keyword.get(mobile_config, :client_id) || configured_web_client_id()
    issuer_name = Keyword.get(mobile_config, :issuer_name, @issuer_name)

    if is_binary(client_id) and client_id != "" do
      Oidcc.ClientContext.from_configuration_worker(issuer_name, client_id, :unauthenticated)
    else
      {:error, :invalid_audience}
    end
  end

  defp configured_web_client_id do
    oidc_provider_config()
    |> Keyword.get(:client_id)
  end

  defp oidc_provider_config do
    :ueberauth_oidcc
    |> Application.get_env(:providers, [])
    |> Keyword.get(:oidc, [])
  end

  defp undefined_to_nil(:undefined), do: nil
  defp undefined_to_nil(value), do: value
end
