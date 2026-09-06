package LANraragi::Plugin::Metadata::HentoidExternal;

use strict;
use warnings;

#Plugins can freely use all Perl packages already installed on the system
#Try however to restrain yourself to the ones already installed for LRR (see tools/cpanfile) to avoid extra installations by the end-user.
use Mojo::JSON qw(from_json);

#You can also use the LRR Internal API when fitting.
use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging qw(get_plugin_logger);
use LANraragi::Utils::Archive qw(is_file_in_archive extract_file_from_archive);

#Meta-information about your plugin.
sub plugin_info {

    return (
        #Standard metadata
        name      => "Hentoid External Sidecar",
        type      => "metadata",
        namespace => "hentoidext",
        author    => "Durandal / adapted via Claude",
        version   => "1.0",
        description =>
          "Reads Hentoid-style metadata from a sidecar JSON file sitting next to the archive on disk "
          . "(e.g. \"MyArchive.cbz\" -> \"MyArchive_h.json\"). Falls back to an embedded contentV2.json if no sidecar is found. "
          . "Parses tags, artists, circles, series, characters, language and category, plus the source URL.",
        icon =>
          "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABhGlDQ1BJQ0MgcHJvZmlsZQAAKJF9kT1Iw1AUhU9TpVoqDmYQcchQnSyIijhKFYtgobQVWnUweekfNDEkKS6OgmvBwZ/FqoOLs64OroIg+APi4uqk6CIl3pcUWsR44fE+zrvn8N59gNCoMs3qGgc03TbTibiUy69IoVeE0QsRAYgys4xkZiEL3/q6pz6quxjP8u/7s/rUgsWAgEQ8ywzTJl4nnt60Dc77xCIryyrxOfGYSRckfuS64vEb55LLAs8UzWx6jlgklkodrHQwK5sa8RRxVNV0yhdyHquctzhr1Rpr3ZO/MFLQlzNcpzWMBBaRRAoSFNRQQRU2YrTrpFhI03ncxz/k+lPkUshVASPHPDagQXb94H/we7ZWcXLCS4rEge4Xx/kYAUK7QLPuON/HjtM8AYLPwJXe9m80gJlP0uttLXoE9G8DF9dtTdkDLneAwSdDNmVXCtISikXg/Yy+KQ8M3ALhVW9urXOcPgBZmtXSDXBwCIyWKHvN5909nXP7t6c1vx8dzXKFeWpUawAAAAZiS0dEAOwAEABqpSa6lwAAAAlwSFlzAAAuIwAALiMBeKU/dgAAAAd0SU1FB+MKCRQBJSKMeg0AAAGVSURBVDjLpZMxa9tQFIXPeaiyhxiZzKFjBme1JFfYgYAe9Bd0yA8JIaQhkJLBP6T/wh3qpZYzm2I8dyilJJMTW7yTIVGRFasE8uAt93K+d+5991IS8Ybj1SVIer24ty8Jk2wyl5S/GkDSi+O4s9PaOYOQh91wSHK2DeLViVut1pmkTwAQtAPUQcz/xCRBEpKOg3ZwEnbDDklvK6AQ+77fds4tSJbBcM7Nm83GbhXiVcXj8fiHpO/WWgfgHAAkXYxGoy8k/UG/nzxDnsqRxF7cO0iS5AhAQxKLm6bpVZqmn8sxAI3kQ2KjKDqQ9GRFEqDNfpQcukrMkDRF3ADAJJvM1+v1n0G/n5D0AcBaew3gFMCFtfbyuVT/cHCYrFarX1mWLQCgsAWSXtgNO81mY/ed7380xpyUn3XOXefr/Ntyufw9vZn+LL7zn21J+fRmOru/f/hrjNmThFLOGWPeV8UvBklSTnIWdsNh0A4g6RiAI/n17vZuWBVvncQNSBAYEK5OvNGDbSMdRdE+AJdl2aJumfjWdX4EIwDvDt7UjSEAAAAASUVORK5CYII=",
        parameters => [
            { type => "bool", desc => "Save archive title from the JSON" },
            { type => "bool", desc => "Save the source URL as a source: tag" }
        ]
    );

}

#Mandatory function to be implemented by your plugin
sub get_tags {

    shift;
    my $lrr_info = shift;                          # Global info hash
    my ( $save_title, $save_source ) = @_;         # Plugin parameters

    my $logger = get_plugin_logger();
    my $file   = $lrr_info->{file_path};

    my $stringjson = read_sidecar_json( $file, $logger );

    # If no sidecar was found on disk, fall back to the classic embedded contentV2.json behaviour.
    my $tempfile;
    unless ( defined $stringjson ) {
        ( $stringjson, $tempfile ) = read_embedded_json( $file, $logger );
    }

    unless ( defined $stringjson ) {
        return ( error => "No Hentoid sidecar (_h.json) or embedded contentV2.json found for this archive!" );
    }

    #Use Mojo::JSON to decode the string into a hash
    my $hashjson = eval { from_json $stringjson };
    if ($@) {
        unlink $tempfile if $tempfile;
        return ( error => "Found a Hentoid JSON but could not parse it: $@" );
    }

    $logger->debug("Found and loaded Hentoid JSON for $file");

    #Parse it
    my ( $tags, $title ) = tags_from_hentoid_json( $hashjson, $save_source );

    #Clean up the temp file if we extracted one from the archive
    unlink $tempfile if $tempfile;

    #Return tags
    $logger->info("Sending the following tags to LRR: $tags");
    if ( $save_title && $title ) {
        $logger->info("Parsed title is $title");
        return ( tags => $tags, title => $title );
    } else {
        return ( tags => $tags );
    }

}

#read_sidecar_json($archive_path, $logger)
#Looks for a "<archive-basename>_h.json" file next to the archive on disk and returns its contents as a string.
#Returns undef if no such file exists.
sub read_sidecar_json {

    my ( $file, $logger ) = @_;

    # Derive the sidecar path by stripping the archive extension and appending _h.json
    # e.g. ".../Some Title.cbz" -> ".../Some Title_h.json"
    my $sidecar = $file;
    $sidecar =~ s/\.[^.]+$//;    # remove the final extension only
    $sidecar .= "_h.json";

    unless ( -e $sidecar ) {
        $logger->debug("No sidecar JSON at $sidecar");
        return undef;
    }

    $logger->debug("Reading sidecar JSON: $sidecar");

    open( my $fh, '<:encoding(UTF-8)', $sidecar )
      or do {
        $logger->warn("Could not open sidecar $sidecar: $!");
        return undef;
      };

    my $stringjson = do { local $/; <$fh> };
    close($fh);

    # Strip a UTF-8 BOM if present
    $stringjson =~ s/^\x{FEFF}//;

    return $stringjson;
}

#read_embedded_json($archive_path, $logger)
#Original Hentoid behaviour: extract contentV2.json (or ContentV2.json) from inside the archive.
#Returns ($string, $tempfilepath) or (undef) if nothing found.
sub read_embedded_json {

    my ( $file, $logger ) = @_;

    my $path_in_archive = is_file_in_archive( $file, "contentV2.json" );
    unless ($path_in_archive) {
        $path_in_archive = is_file_in_archive( $file, "ContentV2.json" );
    }

    return undef unless $path_in_archive;

    my $filepath = extract_file_from_archive( $file, $path_in_archive );

    open( my $fh, '<:encoding(UTF-8)', $filepath )
      or do {
        $logger->warn("Could not open extracted $filepath: $!");
        return undef;
      };

    my $stringjson = do { local $/; <$fh> };
    close($fh);
    $stringjson =~ s/^\x{FEFF}//;

    return ( $stringjson, $filepath );
}

#tags_from_hentoid_json(decodedjson, save_source)
#Goes through the JSON hash obtained from a Hentoid JSON file and returns the contained tags (and title if found).
sub tags_from_hentoid_json {

    my ( $hash, $save_source ) = @_;
    my @found_tags;

    my $attributes = $hash->{"attributes"} || {};
    my $title      = $hash->{"title"};

    my $tags       = $attributes->{"TAG"};
    my $characters = $attributes->{"CHARACTER"};
    my $series     = $attributes->{"SERIE"};
    my $groups     = $attributes->{"CIRCLE"};
    my $artists    = $attributes->{"ARTIST"};
    my $language   = $attributes->{"LANGUAGE"};
    my $categories = $attributes->{"CATEGORY"};

    foreach my $tag (@$tags) {
        push( @found_tags, $tag->{"name"} );
    }

    foreach my $tag (@$artists) {
        push( @found_tags, "artist:" . $tag->{"name"} );
    }

    foreach my $tag (@$groups) {
        push( @found_tags, "group:" . $tag->{"name"} );
    }

    foreach my $tag (@$series) {
        push( @found_tags, "series:" . $tag->{"name"} );
    }

    foreach my $tag (@$characters) {
        push( @found_tags, "character:" . $tag->{"name"} );
    }

    foreach my $tag (@$language) {
        push( @found_tags, "language:" . $tag->{"name"} );
    }

    foreach my $tag (@$categories) {
        push( @found_tags, "category:" . $tag->{"name"} );
    }

    # Add the source URL as a special "source:" tag so LRR shows a clickable link.
    if ( $save_source ) {
        my $url = $hash->{"url"};
        if ( defined $url && $url ne "" ) {
            $url =~ s{^https?://}{};    # LRR stores source: without the protocol
            push( @found_tags, "source:" . $url );
        }
    }

    #Done-o
    my $concat_tags = join( ", ", @found_tags );
    return ( $concat_tags, $title );

}

1;
