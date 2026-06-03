defmodule AutomatronExTest do
  use ExUnit.Case, async: true

  describe "catalog_path/0" do
    test "returns the catalog path configured for the test environment" do
      assert AutomatronEx.catalog_path() ==
               Path.expand("support/fixtures/catalog", __DIR__)
    end
  end
end
