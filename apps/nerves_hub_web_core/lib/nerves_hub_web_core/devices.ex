defmodule NervesHubWebCore.Devices do
  import Ecto.Query

  alias Ecto.{Changeset, Multi}

  alias NervesHubWebCore.{
    Certificate,
    Devices.UpdatePayload,
    Deployments.Deployment,
    Firmwares,
    Firmwares.FirmwareMetadata,
    AuditLogs,
    AuditLogs.AuditLog,
    Accounts.Org,
    Repo
  }

  alias NervesHubWebCore.Devices.{Device, DeviceCertificate, CACertificate}

  def get_device(device_id) do
    Device
    |> Repo.exclude_deleted()
    |> Repo.get(device_id)
  end

  def get_device!(device_id) do
    Device
    |> Repo.exclude_deleted()
    |> Repo.get!(device_id)
  end

  def get_devices_by_org_id(org_id) do
    query =
      from(
        d in Device,
        where: d.org_id == ^org_id
      )

    query
    |> Repo.exclude_deleted()
    |> order_by(asc: :identifier)
    |> Repo.all()
  end

  def get_devices_by_org_id_and_product_id(org_id, product_id) do
    query =
      from(
        d in Device,
        where: d.org_id == ^org_id,
        where: d.product_id == ^product_id
      )

    query
    |> Repo.exclude_deleted()
    |> order_by(asc: :identifier)
    |> Repo.all()
  end

  def get_device_count_by_org_id(org_id) do
    q =
      from(
        d in Device,
        where: d.org_id == ^org_id,
        select: count(d)
      )

    q
    |> Repo.exclude_deleted()
    |> Repo.one!()
  end

  defp device_by_org_query(org_id, device_id) do
    from(
      d in Device,
      where: d.org_id == ^org_id,
      where: d.id == ^device_id
    )
  end

  def get_device_by_org(%Org{id: org_id}, device_id) do
    device_by_org_query(org_id, device_id)
    |> Repo.exclude_deleted()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      device -> {:ok, device}
    end
  end

  def get_device_by_org!(%Org{id: org_id}, device_id) do
    device_by_org_query(org_id, device_id)
    |> Repo.exclude_deleted()
    |> Repo.one!()
  end

  @spec get_device_by_identifier(Org.t(), String.t()) :: {:ok, Device.t()} | {:error, :not_found}
  def get_device_by_identifier(%Org{id: org_id}, identifier) when is_binary(identifier) do
    query =
      from(
        d in Device,
        where: d.identifier == ^identifier and d.org_id == ^org_id,
        preload: [:device_certificates]
      )

    query
    |> Repo.exclude_deleted()
    |> Device.with_org()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      device -> {:ok, device}
    end
  end

  def get_device_by(filters) do
    Repo.get_by(Device, filters)
    |> case do
      nil -> {:error, :not_found}
      device -> {:ok, device}
    end
  end

  def get_eligible_deployments(%Device{firmware_metadata: nil}), do: []

  def get_eligible_deployments(%Device{firmware_metadata: meta} = device) do
    from(
      d in Deployment,
      join: p in assoc(d, :product),
      on: [org_id: ^device.org_id, name: ^meta.product],
      join: f in assoc(d, :firmware),
      on: f.product_id == p.id,
      where: d.is_active,
      where: d.healthy,
      where: f.architecture == ^meta.architecture,
      where: f.platform == ^meta.platform,
      where: f.uuid != ^meta.uuid,
      preload: [firmware: f]
    )
    |> Repo.all()
    |> Enum.filter(fn dep -> matches_deployment?(device, dep) end)
  end

  def get_eligible_deployments(_), do: []

  @doc """
  resolves an update with `resolve_update/2` then dispatches
  the payload over Phoenix PubSub
  """
  def send_update_message(%Device{} = device, %Deployment{} = deployment) do
    %UpdatePayload{} = update_payload = resolve_update(device, deployment)

    if update_payload.update_available do
      Phoenix.PubSub.broadcast(
        NervesHubWeb.PubSub,
        "device:#{device.id}",
        %Phoenix.Socket.Broadcast{
          event: "update",
          payload: update_payload
        }
      )
    end

    update_payload
  end

  @spec create_device(map) ::
          {:ok, Device.t()}
          | {:error, Changeset.t()}
  def create_device(params) do
    %Device{}
    |> Device.changeset(params)
    |> Repo.insert()
  end

  def delete_device(%Device{} = device) do
    device_certificates_query = from(dc in DeviceCertificate, where: dc.device_id == ^device.id)
    changeset = Repo.soft_delete_changeset(device)

    Multi.new()
    |> Multi.delete_all(:device_certificates, device_certificates_query)
    |> Multi.update(:device, changeset)
    |> Repo.transaction()
  end

  @spec create_device_certificate(Device.t(), map) ::
          {:ok, DeviceCertificate.t()}
          | {:error, Changeset.t()}
  def create_device_certificate(%Device{} = device, params) do
    params = Map.put(params, :org_id, device.org_id)

    device
    |> Ecto.build_assoc(:device_certificates)
    |> DeviceCertificate.changeset(params)
    |> Repo.insert()
  end

  def get_device_certificates(%Device{} = device) do
    query =
      from(
        c in DeviceCertificate,
        join: d in assoc(c, :device),
        where: d.id == ^device.id
      )

    Repo.all(query)
  end

  @spec get_device_by_certificate(DeviceCertificate.t()) ::
          {:ok, Device.t()} | {:error, :not_found}
  def get_device_by_certificate(%DeviceCertificate{device: %Ecto.Association.NotLoaded{}} = cert) do
    Repo.preload(cert, :device)
    |> get_device_by_certificate()
  end

  def get_device_by_certificate(%DeviceCertificate{device: %Device{} = device}),
    do: {:ok, Repo.preload(device, :org)}

  def get_device_by_certificate(_), do: {:error, :not_found}

  def get_device_certificate_by_x509(cert) do
    fingerprint = NervesHubWebCore.Certificate.fingerprint(cert)
    aki = NervesHubWebCore.Certificate.get_aki(cert)
    serial = NervesHubWebCore.Certificate.get_serial_number(cert)
    {not_before, not_after} = NervesHubWebCore.Certificate.get_validity(cert)

    query =
      from(
        c in DeviceCertificate,
        where: [fingerprint: ^fingerprint],
        # TODO: Remove lookup by other fields when DER and
        # fingerprints have been captured
        #
        # finerprint == nil is important because an altered cert
        # may still contain the same serial, aki, and validity.
        # However, the fingerprint would be different and not
        # match on the lookup above. So this fallback query
        # should only be considered if we dont already have
        # the fingerprint
        or_where:
          is_nil(c.fingerprint) and
            c.serial == ^serial and
            c.aki == ^aki and
            c.not_before == ^not_before and
            c.not_after == ^not_after
      )

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      certificate -> {:ok, certificate}
    end
  end

  def get_device_certificates_by_public_key(otp_cert) do
    pk_fingerprint = NervesHubWebCore.Certificate.public_key_fingerprint(otp_cert)

    from(c in DeviceCertificate,
      where: [public_key_fingerprint: ^pk_fingerprint],
      preload: [:device]
    )
    |> Repo.all()
  end

  @spec get_device_certificate_by_device_and_serial(Device.t(), binary) ::
          {:ok, DeviceCertificate.t()} | {:error, any()}
  def get_device_certificate_by_device_and_serial(%Device{id: device_id}, serial) do
    query =
      from(
        dc in DeviceCertificate,
        where: dc.serial == ^serial and dc.device_id == ^device_id
      )

    query
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      device_certificate ->
        {:ok, device_certificate}
    end
  end

  def update_device_certificate(%DeviceCertificate{} = certificate, params) do
    certificate
    |> DeviceCertificate.update_changeset(params)
    |> Repo.update()
  end

  @spec delete_device_certificate(DeviceCertificate.t()) ::
          {:ok, DeviceCertificate.t()}
          | {:error, Changeset.t()}
  def delete_device_certificate(%DeviceCertificate{} = device_certificate) do
    Repo.delete(device_certificate)
  end

  @spec create_ca_certificate(Org.t(), map()) ::
          {:ok, CACertificate.t()}
          | {:error, Changeset.t()}
  def create_ca_certificate(%Org{} = org, params) do
    org
    |> Ecto.build_assoc(:ca_certificates)
    |> CACertificate.changeset(params)
    |> Repo.insert()
  end

  @spec create_ca_certificate_from_x509(Org.t(), X509.Certificate.t(), binary() | nil) ::
          {:ok, CACertificate.t()} | {:error, Ecto.Changeset.t()}
  def create_ca_certificate_from_x509(%Org{} = org, otp_cert, description \\ nil)
      when is_tuple(otp_cert) do
    {not_before, not_after} = Certificate.get_validity(otp_cert)

    params = %{
      serial: Certificate.get_serial_number(otp_cert),
      aki: Certificate.get_aki(otp_cert),
      ski: Certificate.get_ski(otp_cert),
      not_before: not_before,
      not_after: not_after,
      der: X509.Certificate.to_der(otp_cert),
      description: description
    }

    create_ca_certificate(org, params)
  end

  def get_ca_certificates(%Org{id: org_id}) do
    from(ca in CACertificate, where: ca.org_id == ^org_id)
    |> Repo.all()
  end

  @spec get_ca_certificate_by_aki(binary) :: {:ok, CACertificate.t()} | {:error, any()}
  def get_ca_certificate_by_aki(aki) do
    Repo.get_by(CACertificate, aki: aki)
    |> case do
      nil -> {:error, :not_found}
      ca_cert -> {:ok, ca_cert}
    end
  end

  @spec get_ca_certificate_by_ski(binary) :: {:ok, CACertificate.t()} | {:error, any()}
  def get_ca_certificate_by_ski(ski) do
    Repo.get_by(CACertificate, ski: ski)
    |> case do
      nil -> {:error, :not_found}
      ca_cert -> {:ok, ca_cert}
    end
  end

  @spec get_ca_certificate_by_serial(binary) :: {:ok, CACertificate.t()} | {:error, any()}
  def get_ca_certificate_by_serial(serial) do
    Repo.get_by(CACertificate, serial: serial)
    |> case do
      nil -> {:error, :not_found}
      ca_cert -> {:ok, ca_cert}
    end
  end

  @spec get_ca_certificate_by_org_and_serial(Org.t(), binary) ::
          {:ok, CACertificate.t()} | {:error, any()}
  def get_ca_certificate_by_org_and_serial(%Org{id: org_id}, serial) do
    query =
      from(
        ca in CACertificate,
        where: ca.serial == ^serial and ca.org_id == ^org_id
      )

    query
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      ca_certificate ->
        {:ok, ca_certificate}
    end
  end

  def update_ca_certificate(%CACertificate{} = certificate, params) do
    certificate
    |> CACertificate.update_changeset(params)
    |> Repo.update()
  end

  def delete_ca_certificate(%CACertificate{} = ca_certificate) do
    Repo.delete(ca_certificate)
  end

  def device_connected(device) do
    last_communication = DateTime.utc_now()

    AuditLogs.audit!(device, device, :update, %{
      last_communication: last_communication
    })

    update_device(device, %{last_communication: last_communication})
  end

  def update_firmware_metadata(device, nil) do
    {:ok, device}
  end

  def update_firmware_metadata(device, metadata) do
    update_device(device, %{firmware_metadata: metadata})
  end

  def update_device(%Device{} = device, params) do
    device
    |> Device.changeset(params)
    |> Repo.update()
    |> case do
      {:ok, %{healthy: false} = device} ->
        {:ok, device}

      {:ok, device} ->
        # Get deployments with new changed device.
        # This will dispatch an update if `tags` is updated for example.
        task =
          Task.Supervisor.async(NervesHubWebCore.TaskSupervisor, fn ->
            case get_eligible_deployments(device) do
              [%Deployment{} = deployment | _] ->
                send_update_message(device, deployment)

              _ ->
                {:ok, device}
            end
          end)

        Task.await(task, 15000)
        {:ok, device}

      error ->
        error
    end
  end

  @doc """
  Finds a matching deployment for a device based on it's current firmware meta and
  health status.
  """
  @spec resolve_update(Device.t(), deployments :: [Deployment.t()] | Deployment.t()) ::
          UpdatePayload.t()
  def resolve_update(_device, _deployments = []), do: %UpdatePayload{update_available: false}

  def resolve_update(_device, %Deployment{healthy: false}) do
    %UpdatePayload{update_available: false}
  end

  def resolve_update(%Device{firmware_metadata: nil}, _deployment) do
    %UpdatePayload{update_available: false}
  end

  def resolve_update(device, [%Deployment{} = deployment | _]) do
    resolve_update(device, deployment)
  end

  def resolve_update(
        %Device{firmware_metadata: %{uuid: uuid}} = device,
        %Deployment{} = deployment
      ) do
    with {:ok, %{healthy: true}} <- verify_update_eligibility(device, deployment),
         true <- matches_deployment?(device, deployment),
         %Device{product: product} <- Repo.preload(device, :product),
         fwup_version <- Map.get(device.firmware_metadata, :fwup_version),
         %{firmware: target} <- Repo.preload(deployment, :firmware) do
      source =
        case Firmwares.get_firmware_by_product_and_uuid(product, uuid) do
          {:ok, source} -> source
          {:error, :not_found} -> nil
        end

      {:ok, url} = Firmwares.get_firmware_url(source, target, fwup_version, product)
      {:ok, meta} = Firmwares.metadata_from_firmware(target)

      %UpdatePayload{
        update_available: true,
        firmware_url: url,
        firmware_meta: meta,
        deployment: deployment,
        deployment_id: deployment.id
      }
    else
      _ -> %UpdatePayload{update_available: false}
    end
  end

  @doc """
  Returns true if Version.match? and all deployment tags are in device tags.
  """
  def matches_deployment?(
        %Device{tags: tags, firmware_metadata: %FirmwareMetadata{version: version}},
        %Deployment{conditions: %{"version" => requirement, "tags" => dep_tags}}
      ) do
    if version_match?(version, requirement) and tags_match?(tags, dep_tags) do
      true
    else
      false
    end
  end

  def matches_deployment?(_, _), do: false

  @spec failure_threshold_met?(Device.t(), Deployment.t()) :: boolean()
  def failure_threshold_met?(%Device{} = device, %Deployment{} = deployment) do
    failures_query(device, deployment)
    |> Repo.all()
    |> length()
    |> Kernel.>=(deployment.device_failure_threshold)
  end

  @spec failure_rate_met?(Device.t(), Deployment.t()) :: boolean()
  def failure_rate_met?(%Device{} = device, %Deployment{} = deployment) do
    seconds_ago =
      Timex.shift(DateTime.utc_now(), seconds: -deployment.device_failure_rate_seconds)

    failures_query(device, deployment)
    |> where([al], al.inserted_at >= ^seconds_ago)
    |> Repo.all()
    |> length()
    |> Kernel.>=(deployment.device_failure_rate_amount)
  end

  def verify_update_eligibility(%{healthy: false} = device, _deployment) do
    {:ok, device}
  end

  def verify_update_eligibility(device, deployment) do
    cond do
      failure_rate_met?(device, deployment) ->
        AuditLogs.audit!(deployment, device, :update, %{
          healthy: false,
          reason: "device failure rate met"
        })

        update_device(device, %{healthy: false})

      failure_threshold_met?(device, deployment) ->
        AuditLogs.audit!(deployment, device, :update, %{
          healthy: false,
          reason: "device failure threshold met"
        })

        update_device(device, %{healthy: false})

      true ->
        {:ok, device}
    end
  end

  defp failures_query(%Device{id: device_id}, %Deployment{id: deployment_id} = deployment) do
    deployment = Repo.preload(deployment, :firmware)

    from(
      al in AuditLog,
      where: [
        actor_id: ^deployment_id,
        actor_type: ^to_string(Deployment),
        resource_type: ^to_string(Device),
        resource_id: ^device_id
      ],
      where:
        fragment(
          """
          (params->>'firmware_uuid' = ?) AND
          (params->>'send_update_message' = 'true')
          """,
          ^deployment.firmware.uuid
        ),
      # Handle edge case we may make 2 audit log events at the same time
      distinct: true,
      select: al.inserted_at
    )
  end

  defp version_match?(_vsn, ""), do: true

  defp version_match?(version, requirement) do
    Version.match?(version, requirement)
  end

  defp tags_match?(device_tags, deployment_tags) do
    Enum.all?(deployment_tags, fn tag -> tag in device_tags end)
  end
end
