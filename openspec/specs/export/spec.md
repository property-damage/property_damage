# Export Specification

## Purpose

Export converts PropertyDamage failure reports into portable, self-contained formats that can be shared, executed, and used for regression testing without requiring the PropertyDamage framework. Supported formats include ExUnit regression tests, standalone scripts (curl/bash, Python, Elixir), and interactive LiveBook notebooks.

## Requirements

### Requirement: Export Hub

The system SHALL provide a central entry point for converting failure reports to all supported portable formats.

#### Scenario: Export to string

- **WHEN** a failure report is exported to a format (`:exunit`, `{:script, :curl}`, `{:script, :python}`, `{:script, :elixir}`, `:livebook`)
- **THEN** the system SHALL return the formatted content as a string

#### Scenario: Export to file

- **WHEN** `Export.save(failure, directory, format)` is called
- **THEN** the system SHALL write the exported content to a file in the specified directory and return `{:ok, path}`

#### Scenario: Export all formats

- **WHEN** `Export.save_all(failure, directory, opts)` is called
- **THEN** the system SHALL generate and save all supported formats and return `{:ok, paths}` with paths to each file

### Requirement: ExUnit Export

The system SHALL generate ExUnit regression test files from failure reports that reproduce the failure using PropertyDamage.

#### Scenario: Generate regression test module

- **WHEN** a failure report is exported to ExUnit format
- **THEN** the generated code SHALL be a valid ExUnit test module containing a test that runs PropertyDamage with the original seed

#### Scenario: Configurable module and test names

- **WHEN** `:module_name` or `:test_name` options are provided
- **THEN** the generated test SHALL use those names
- **AND** if omitted, names SHALL be auto-generated from failure metadata

#### Scenario: Expect-fixed mode

- **WHEN** `:expect_fixed` is set to `true`
- **THEN** the generated test SHALL expect the test to pass rather than fail

#### Scenario: Self-contained output

- **WHEN** an ExUnit test is generated
- **THEN** it SHALL include a moduledoc describing the original failure, the model and adapter modules, and the seed for reproduction

### Requirement: Script Export

The system SHALL generate standalone scripts in multiple languages that reproduce the failure via HTTP calls without PropertyDamage installed.

#### Scenario: Curl/bash script generation

- **WHEN** a failure report is exported with language `:curl` or `:bash`
- **THEN** the system SHALL generate a bash script with curl commands and a `.sh` file extension

#### Scenario: Python script generation

- **WHEN** a failure report is exported with language `:python`
- **THEN** the system SHALL generate a Python script using the requests library and a `.py` file extension

#### Scenario: Elixir script generation

- **WHEN** a failure report is exported with language `:elixir`
- **THEN** the system SHALL generate an Elixir script using the Req HTTP client and a `.exs` file extension

#### Scenario: Base URL configuration

- **WHEN** a script is generated
- **THEN** the `:base_url` option SHALL configure the target server URL
- **AND** an environment variable (default `BASE_URL`) MAY be used for runtime override

#### Scenario: Runnable without PropertyDamage

- **WHEN** a generated script is executed
- **THEN** it SHALL be self-contained and runnable using only its language runtime and standard HTTP libraries

### Requirement: LiveBook Export

The system SHALL generate interactive LiveBook notebooks from failure reports for exploratory debugging.

#### Scenario: Notebook generation

- **WHEN** a failure report is exported to LiveBook format
- **THEN** the system SHALL produce a `.livemd` file with setup, per-command execution sections, and HTTP calls via Req

#### Scenario: State tracking

- **WHEN** `:include_state_tracking` is `true` (default)
- **THEN** each command section SHALL track and display the model state alongside execution

#### Scenario: Exploration section

- **WHEN** `:include_exploration` is `true` (default)
- **THEN** the notebook SHALL include a section for "what-if" scenario exploration

#### Scenario: Step-by-step execution

- **WHEN** a LiveBook notebook is opened
- **THEN** each command SHALL be in a separate cell allowing individual execution and inspection

### Requirement: HTTP Spec

The system SHALL define a transport specification for mapping commands to HTTP requests and responses, enabling script generation.

#### Scenario: Command to HTTP mapping

- **WHEN** an adapter implements `http_spec/2`
- **THEN** it SHALL return an `HTTPSpec` struct with method, path, body, headers, path_params, and query_params

#### Scenario: Path parameter substitution

- **WHEN** a path contains `:param_name` segments and corresponding `path_params` are provided
- **THEN** the system SHALL substitute the parameter values into the path

#### Scenario: Supported HTTP methods

- **WHEN** an HTTPSpec is created
- **THEN** the method SHALL be one of `:get`, `:post`, `:put`, `:patch`, `:delete`, `:head`, or `:options`

### Requirement: ExUnit Integration

The system SHALL provide macros for running PropertyDamage property tests within ExUnit test suites.

#### Scenario: Property test macro

- **WHEN** `use PropertyDamage.ExUnit` is called in a test module
- **THEN** the `property_damage/2` macro SHALL be available for defining property-based tests

#### Scenario: Test configuration

- **WHEN** a `property_damage` test is defined
- **THEN** it MUST accept `:model` and `:adapter` as required options
- **AND** it SHOULD accept optional `:max_commands`, `:max_runs`, `:seed`, `:shrink`, and `:adapter_config`

#### Scenario: Failure output formatting

- **WHEN** a property test fails
- **THEN** the output SHALL include the seed for reproduction, the original command sequence, the shrunk command sequence, the failure reason, and reproduction instructions
