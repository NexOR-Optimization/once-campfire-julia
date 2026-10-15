#!/usr/bin/env ruby
# Portable reproduction of the recorded C / Julia 4,0 / Julia 2,2 rotation.
# Only local source-path discovery and a measured-revision guard differ from
# the original alias wrapper. This script runs a NEW benchmark when invoked.
# Only app registration, runtime alias mapping and source selection are changed
# after the repository's standard Julia adapter. Every replacement is checked.
require File.join(File.expand_path(ENV.fetch('JULIA_SOURCE')), 'julia/bench/compare')
require 'open3'

source_head, status = Open3.capture2('git', '-C', CampfireComparisonAdapter::SOURCE, 'rev-parse', 'HEAD')
raise 'Check out the documented measured standalone revision first' unless status.success? && source_head.strip == '8a4feb2f27af0929290f0c8162d85f28784055a4'
raise 'Measured runtime source differs' unless CampfireComparisonAdapter.runtime_digest(CampfireComparisonAdapter::SOURCE) == '7ecf3edc38e20ca43ec609e56ecf12698917794fc28db98b7adf246e955a9c8a'

module CampfirePairedComparison
  FILE = File.expand_path(__FILE__)
  APPS = %w[julia-4-0 julia-2-2].freeze
  SOURCES = {
    'julia-4-0' => CampfireComparisonAdapter::SOURCE,
    'julia-2-2' => CampfireComparisonAdapter::SOURCE
  }.freeze

  def self.source_for(app)
    SOURCES.fetch(app)
  end

  def self.adapt(source)
    substitutions = [
      ['allowed = %w[rails django laravel express express-bun elixir go rust c cpp julia]',
       'allowed = %w[rails django laravel express express-bun elixir go rust c cpp julia julia-4-0 julia-2-2]'],
      ['runtimes = apps.to_h { |app| [app, app == "express-bun" ? "express" : app] }',
       'runtimes = apps.to_h { |app| [app, CampfirePairedComparison::APPS.include?(app) ? "julia" : (app == "express-bun" ? "express" : app)] }'],
      ['source = kind == "julia" ? CampfireComparisonAdapter::SOURCE : File.join(options[:workspace], kind == "rails" ? "once-campfire" : "once-campfire-#{kind}")',
       'source = kind == "julia" ? CampfirePairedComparison.source_for(app) : File.join(options[:workspace], kind == "rails" ? "once-campfire" : "once-campfire-#{kind}")']
    ]
    replacements = []
    substitutions.each do |before, after|
      source = CampfireComparisonAdapter.replace_once(source, before, after)
      replacements << {
        occurrences: 1, before: before, after: after,
        before_sha256: Digest::SHA256.hexdigest(before),
        after_sha256: Digest::SHA256.hexdigest(after)
      }
    end
    [source, replacements]
  end
end

class << CampfireComparisonAdapter
  alias_method :prepare_unpaired, :prepare

  def prepare(path)
    unpaired = prepare_unpaired(path)
    adapted, replacements = CampfirePairedComparison.adapt(unpaired)
    @metadata = @metadata.merge(
      julia_adapter_adapted_comparison_sha256: Digest::SHA256.hexdigest(unpaired),
      adapted_comparison_sha256: Digest::SHA256.hexdigest(adapted),
      adaptations: @metadata.fetch(:adaptations) + %w[paired-julia-aliases paired-runtime-mapping paired-source-selection],
      paired_adapter: {
        name: 'campfire-paired-julia-comparison-v1',
        source: CampfirePairedComparison::FILE,
        source_sha256: Digest::SHA256.file(CampfirePairedComparison::FILE).hexdigest,
        sources: CampfirePairedComparison::SOURCES,
        runtime_kinds: CampfirePairedComparison::APPS.to_h { |app| [app, 'julia'] },
        replacements: replacements,
        load_generator: 'unchanged upstream', response_contracts: 'unchanged upstream',
        persisted_write_audits: 'unchanged upstream',
        environment: CampfirePairedComparison::APPS.to_h do |app|
          key = app.upcase.tr('-', '_')
          [app, JSON.parse(ENV.fetch("#{key}_BENCH_ENV"))]
        end
      }
    )
    adapted
  end
end

CampfireComparisonAdapter.run(ARGV) if $PROGRAM_NAME == __FILE__
