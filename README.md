# scatter_gather

A Ruby gem that provides a scatter-gather pattern for coordinating ActiveJob execution. Jobs can wait for other jobs to complete before executing, with configurable polling, retry, and timeout behavior.

## Usage

Start some scatter jobs and create a gather job that waits for all dependencies to complete:

```ruby
class EmailProcessorJob < ActiveJob::Base
  include ScatterGather

  def perform(email_id)
    # Process email
  end
end

class AttachmentProcessorJob < ActiveJob::Base
  include ScatterGather

  def perform(email_id)
    # Process attachments
  end
end

class AICategorizerJob < ActiveJob::Base
  include ScatterGather

  def perform(email_id)
    # Categorize email with AI
  end
end

class NotifyCompleteJob < ActiveJob::Base
  include ScatterGather

  def perform(email_id)
    # Notify that all processing is complete
  end
end

# Start the scatter jobs
email_parser_job = EmailProcessorJob.perform_later(email_id: 123)
attachment_processor_job = AttachmentProcessorJob.perform_later(email_id: 123)
ai_categorizer_job = AICategorizerJob.perform_later(email_id: 123)

# Create a gather job that waits for all dependencies to complete
NotifyCompleteJob.gather(email_parser_job, attachment_processor_job, ai_categorizer_job).perform_later(email_id: 123)
```

The gather job will:
- Check if all dependencies are complete
- If complete: enqueue the target job immediately
- If not complete: poll every 2 seconds (configurable), re-enqueuing itself
- After 10 attempts (configurable): discard with error reporting

### Configuration Options

- `max_attempts`: Number of polling attempts before giving up (default: 10)
- `poll_interval`: Time between polling attempts (default: 2.seconds)

```ruby
# Example with custom configuration
TouchingJob.gather(jobs, poll_interval: 0.2.seconds, max_attempts: 4).perform_later(final_path)
```

## Installation

Add the gem to the application's Gemfile, and then generate and run the migration:

    $ bundle add scatter_gather
    $ bundle install
    $ bin/rails g scatter_gather:install
    $ bin/rails db:migrate

## Development

After checking out the repo, run `bundle` to install dependencies. The development process from there on is like any other gem.

## License

This gem is made available under the MIT license

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/julik/scatter_gather.
