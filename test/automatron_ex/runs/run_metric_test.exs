defmodule AutomatronEx.Runs.RunMetricTest do
  @moduledoc """
  Guards that the embedded metric set stays in parity with its two neighbours:
  `Catalog.Metrics` (the producer) and the `Run` resource (the columns). If a
  metric is added/removed in one place but not the others, these fail.
  """

  use ExUnit.Case, async: true

  alias AutomatronEx.Catalog.Metrics
  alias AutomatronEx.Runs.{Run, RunMetric}

  test "keys match the Catalog.Metrics output exactly" do
    assert Enum.sort(RunMetric.keys()) ==
             Metrics.empty_metrics() |> Map.keys() |> Enum.sort()
  end

  test "there are exactly 12 metric fields" do
    assert length(RunMetric.keys()) == 12
  end

  test "every metric key is a public attribute on the Run resource" do
    public = Run |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(RunMetric.keys()), public)
  end
end
