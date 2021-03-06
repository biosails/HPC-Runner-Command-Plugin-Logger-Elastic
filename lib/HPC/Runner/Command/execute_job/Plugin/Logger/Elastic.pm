package HPC::Runner::Command::execute_job::Plugin::Logger::Elastic;

use Moose::Role;
use Data::Dumper;
use DateTime;
use JSON;
use Try::Tiny;

with 'HPC::Runner::Command::Plugin::Logger::Elastic';

##TODO Create Logger base class

=head1 HPC::Runner::Command::execute_job::Plugin::Logger::Elastic;

=cut

=head2 Attributes

=cut

=head2 Subroutines

=cut

around 'start_command_log' => sub {
    my $orig   = shift;
    my $self   = shift;
    my $cmdpid = shift;

    $self->create_elastic_task($cmdpid);

    $self->$orig($cmdpid);
};

around 'log_table' => sub {
    my $orig = shift;
    my $self = shift;

    $self->$orig(@_);
    $self->update_elastic_task;
};

sub create_elastic_task {
    my $self   = shift;
    my $cmdpid = shift;

    return unless $self->elasticsearch;

    my $job_meta = {};

    if ( $self->metastr ) {
        $job_meta = decode_json( $self->metastr );
    }

    if ( !exists $job_meta->{jobname} ) {
        $job_meta->{jobname} = 'undefined';
    }

    my $task_obj = {
        submission_id => $self->submission_id,
        pid           => $cmdpid,
        start_time    => reformat_time( $self->table_data->{start_time} ),
        jobname       => $job_meta->{jobname},
        job_meta      => $job_meta,
    };

    $task_obj->{task_id} = $self->task_id if $self->can('task_id');
    $task_obj->{scheduler_id} = $self->job_scheduler_id
      if $self->can('scheduler_id');

    my $doc;
    try {
        $doc = $self->elasticsearch->index(
            index => 'hpcrunner',
            type  => 'task',
            body  => $task_obj,
        );
    }
    catch {
        $self->app_log->info('We were not able to index the task!');
        $self->app_log->info( 'Error ' . $_ );
    };

    ##TODO error checking ... so much error checking
    if ( !$doc || !exists $doc->{_id} ) {
        $self->app_log->info('We were not able to index the task!');
    }
    else {
        $self->table_data->{doc_id} = $doc->{_id};
    }
}

sub update_elastic_task {
    my $self = shift;

    return unless $self->elasticsearch;

    my $tags = "";
    if ( exists $self->table_data->{task_tags} ) {
        my $task_tags = $self->table_data->{task_tags};
        if ($task_tags) {
            $tags = $task_tags;
        }
    }

    my $started_task = $self->elasticsearch->get(
        index => 'hpcrunner',
        type  => 'task',
        id    => $self->table_data->{doc_id}
    );

    my $updated_task = $self->elasticsearch->update(
        index => 'hpcrunner',
        type  => 'task',
        id    => $started_task->{_id},
        body  => {
            doc => {
                exit_time => reformat_time( $self->table_data->{exit_time} ),
                duration  => $self->table_data->{duration},
                exit_code => $self->table_data->{exitcode},
                task_tags => $tags,
            }
        }
    );

    my $final_task = $self->elasticsearch->get(
        index => 'hpcrunner',
        type  => 'task',
        id    => $self->table_data->{doc_id}
    );
}

##TODO create interface for exporting variables as environmental variables
## HPCR_PLUGIN_SHORTCODE_VAR
around 'execute' => sub {
    my $orig = shift;
    my $self = shift;

    $ENV{'HPCR_ES_SUBMISSION_ID'} = $self->submission_id;

    $self->$orig();
};

##Make elasticsearch time format happy
sub reformat_time {
    my $time = shift;

    my @dt = split( ' ', $time );
    return $dt[0] . 'T' . $dt[1];
}

1;
