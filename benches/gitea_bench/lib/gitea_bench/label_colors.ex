defmodule GiteaBench.LabelColors do
  @moduledoc """
  Each label's color as the forge reports it, keyed by repo and label name.

  `GiteaBench.State` keeps only label names, because no invariant of the model
  depends on a color. The color is still observable state: the same
  `CreateLabel` intent must give the same color over either transport. The
  observation `label_colors/2` lets a run with two targets compare it after
  every `CreateLabel`. Repo and label names are chosen by the client and are the
  same on both forges, so the key holds no server id.
  """

  use PropertyDamage.Model.Projection

  alias GiteaBench.Commands.CreateLabel
  alias GiteaBench.Events.LabelCreated

  @impl true
  def init, do: %{}

  @impl true
  def apply(colors, %LabelCreated{full_name: full_name, name: name, color: color}) do
    Map.put(colors, {full_name, name}, color)
  end

  def apply(colors, _event), do: colors

  @compare every: CreateLabel
  def label_colors(colors, _root), do: colors
end
