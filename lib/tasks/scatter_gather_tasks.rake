# frozen_string_literal: true

namespace :scatter_gather do
  desc "Recover all journeys hanging in the 'performing' state"
  task :recovery do
    ScatterGather::RecoverStuckJourneysJob.perform_now
  end
end
