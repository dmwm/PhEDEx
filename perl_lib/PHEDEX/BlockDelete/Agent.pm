package PHEDEX::BlockDelete::Agent;
use strict;
use warnings;
use base 'PHEDEX::Core::Agent', 'PHEDEX::Core::Logging';
use PHEDEX::Core::Timing;
use PHEDEX::Core::DB;

sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = $class->SUPER::new(@_);
    my %params = (DBCONFIG => undef,		# Database configuration file
		  MYNODE => undef,		# My TMDB node
		  ONCE => 0,			# Quit after one run
		  WAITTIME => 120 + rand(30));	# Agent cycle time
    my %args = (@_);
    map { $$self{$_} = $args{$_} || $params{$_} } keys %params;
    bless $self, $class;
    return $self;
}

# Called by agent main routine before sleeping.  Do some work.
sub idle
{
    my ($self, @pending) = @_;
    my $dbh = undef;

    eval
    {
	$dbh = $self->connectAgent();
	my $now = &mytimeofday();

	# Trigger deletion of finished blocks at the source end of a complete "move" subscription
	# We trigger for blocks which:
	#   1. Have a block replica at some potential source node
	#   2. Do not have a subscription
	#   3. Are not already in the deletion table (TODO:  faster cleanup of deletion table?)
        #   4. Are not the buffer node of the destination
        #   5. Are not a T1 node
	my ($stmt, $nrow) = &dbexec($dbh, qq{
	    insert into t_dps_block_delete
                   (block, dataset, node, time_request)
	    select distinct sb.id, sb.dataset, br.node, :now
              from t_dps_subscription s
              join t_dps_block sb on sb.dataset = s.dataset or sb.id = s.block
              join t_dps_block_dest bd on bd.destination = s.destination
                                      and bd.block = sb.id
              join t_dps_block_replica br on br.node != s.destination
	                                 and br.block = sb.id
              join t_adm_node n on n.id = br.node
         left join t_dps_block_delete bdel on bdel.node = br.node
                                          and bdel.block = br.block
         left join t_dps_subscription s2 on s2.destination = br.node
                                        and (s2.dataset = sb.dataset or s2.block = sb.id)
             where s.is_move = 'y'
	       and bd.state = 3
	       and bdel.block is null
	       and s2.destination is null
               and n.name not like 'T1_%'
               and not exists (select 1 from t_adm_node buf
                                 join t_adm_link loc on loc.from_node = buf.id and loc.is_local = 'y'
                                 join t_adm_node mss on mss.id = loc.to_node
                                where buf.kind = 'Buffer' and mss.kind = 'MSS'
                                  and buf.id = br.node and mss.id = s.destination)
	   }, ':now' => $now);

	# Log what we just triggered
	my $q_move = &dbexec($dbh, qq{
	    select n.name, b.name
              from t_dps_block_delete bd
	      join t_adm_node n on n.id = bd.node
              join t_dps_block b on b.id = bd.block
	     where bd.time_request = :now
	 }, ':now' => $now);

	while (my ($node, $block) = $q_move->fetchrow()) {
	    $self->Logmsg("triggered deletion of $block at $node due to a move");
	}

	# Issue file deletion requests for block replicas scheduled
	# for deletion and for which no deletion request yet exists.
	# Take care not to create deletion requests for actively
	# transferring files/blocks:
	#   - no block destination
	#   - no file request
	#   - no transfer task (incoming or outgoing)
	($stmt, $nrow) = &dbexec($dbh, qq{
	   insert into t_xfer_delete (fileid, node, time_request)
	   (select f.id, bd.node, bd.time_request
	    from t_dps_block_delete bd
	      join t_xfer_file f
	        on f.inblock = bd.block
              left join t_dps_block_dest dest
                on dest.block = bd.block and dest.destination = bd.node
              left join t_xfer_request xq
                on xq.fileid = f.id and xq.destination = bd.node
	      left join t_xfer_task xt
                on xt.fileid = f.id
               and (xt.from_node = bd.node or xt.to_node = bd.node)
	      left join t_xfer_delete xd
	        on xd.fileid = f.id and xd.node = bd.node
	    where xd.fileid is null
              and dest.block is null
              and xq.fileid is null
              and xt.id is null
              and bd.time_complete is null)});
	$self->Logmsg ("$nrow file deletions scheduled") if $nrow > 0;

        # Mark the block deletion request completed if it has file
        # deletion requests and they are all completed.
	($stmt, $nrow) = &dbexec ($dbh, qq{
          merge into t_dps_block_delete bd
          using (select xd.node, xf.inblock, b.files n_files,
                        count(*) n_exist, sum(nvl2(xd.time_complete, 1, 0)) n_complete
                   from t_xfer_delete xd
	           join t_xfer_file xf on xf.id = xd.fileid
                   join t_dps_block_delete bd on xd.node = bd.node and bd.block = xf.inblock
                   join t_dps_block b on b.id = bd.block
		  where bd.time_complete is null
	          group by xd.node, xf.inblock, b.files) d_check
             on (d_check.node = bd.node
                 and d_check.inblock = bd.block
                 and d_check.n_exist != 0
                 and d_check.n_files <= d_check.n_exist
                 and d_check.n_exist = d_check.n_complete)
          when matched then update set bd.time_complete = :now
      }, ':now' => $now);

	# Remove file deletion requests for completed block deletions
	($stmt, $nrow) = &dbexec ($dbh, qq{
	    delete from t_xfer_delete xd
             where exists ( select 1 from t_dps_block_delete bd
                              join t_xfer_file xf on xf.inblock = bd.block
                             where xd.node = bd.node and xd.fileid = xf.id
			    and bd.time_complete is not null )
	 });

	# Log what we just finished deleting
	my $q_done = &dbexec($dbh, qq{
	    select n.name, b.name
              from t_dps_block_delete bd
	      join t_adm_node n on n.id = bd.node
              join t_dps_block b on b.id = bd.block
	     where bd.time_complete = :now
	 }, ':now' => $now);

	while (my ($node, $block) = $q_done->fetchrow()) {
	    $self->Logmsg("deletion of $block at $node finished");
	}

	# Clean up
	# Delete requests for file and block deletion after 3 days
	my $old = $now - 3*24*3600;
	&dbexec($dbh,qq{delete from t_xfer_delete where time_complete < :old}, ':old' => $old);
	&dbexec($dbh,qq{delete from t_dps_block_delete where time_complete < :old}, ':old' => $old);
	# Delete requests for block deletion from empty blocks
	&dbexec($dbh,qq{delete from t_dps_block_delete bd
                         where exists
                           (select 1 from t_dps_block b
			     where b.files = 0 and b.id = bd.block) });

    	$dbh->commit();
    };
    do { chomp ($@); $self->Alert ("database error: $@");
	 eval { $dbh->rollback() } if $dbh; } if $@;

    # Disconnect from the database
    $self->disconnectAgent();

    $self->doStop() if $$self{ONCE};
}

1;
