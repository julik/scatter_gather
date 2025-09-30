# frozen_string_literal: true

require_relative "lib/scatter_gather/version"

Gem::Specification.new do |spec|
  spec.name = "scatter_gather"
  spec.version = ScatterGather::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]
  spec.license = "MIT"

  spec.summary = "Scatter-gather for ActiveJob"
  spec.description = "Scatter-gather for ActiveJob allowing batching"
  spec.homepage = "https://github.com/julik/scatter_gather"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/julik/scatter_gather"
  spec.metadata["changelog_uri"] = "https://github.com/julik/scatter_gather/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      File.basename(f).start_with?(".")
    end
  end

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7"
  spec.add_dependency "activejob"
  spec.add_dependency "railties"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rails", "~> 7.0"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "standard", "~> 1.51.1", "< 2.0"
  spec.add_development_dependency "magic_frozen_string_literal"
  spec.add_development_dependency "yard"
  spec.add_development_dependency "redcarpet" # needed for the yard gem to enable Github Flavored Markdown
  spec.add_development_dependency "sord"
end
