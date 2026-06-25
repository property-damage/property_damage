defmodule GiteaBench.Events do
  @moduledoc """
  Events the adapters emit, defined once and shared by both transports.

  The same event structs are produced whether a command ran via the REST API or
  the Playwright UI, which is what makes the differential oracle an apples-to-apples
  comparison. Each "created" event carries both the **requested** value (what the
  command asked for) and the **observed** value (what the SUT actually reflects),
  so a transport that silently drops or mangles an attribute is caught even in a
  single-transport run, not only by the cross-transport oracle.

  Server-assigned ids are kept as plain fields: the API adapter fills the real id,
  the UI adapter leaves it `nil`, and `:structural` equivalence ignores `:id`, so
  they never cause a spurious divergence. Entities are linked across commands by
  stable, client-chosen names (login, `owner/name`, per-repo issue number), never
  by server id, so both transports navigate to the same logical entity.
  """

  defmodule UserCreated do
    @moduledoc false
    defstruct [:requested_login, :login, :id]
  end

  defmodule RepoCreated do
    @moduledoc false
    defstruct [:owner, :requested_name, :name, :full_name, :id]
  end

  defmodule IssueCreated do
    @moduledoc false
    defstruct [:full_name, :number, :requested_title, :title, :id]
  end

  defmodule LabelCreated do
    @moduledoc false
    defstruct [:full_name, :requested_name, :name, :color, :id]
  end

  defmodule LabelAssigned do
    @moduledoc false
    # `requested_label` is what the command asked to assign; `labels` is the
    # issue's full observed label set after the operation (sorted names).
    defstruct [:full_name, :number, :requested_label, :labels]
  end

  defmodule IssueClosed do
    @moduledoc false
    defstruct [:full_name, :number, :state]
  end
end
