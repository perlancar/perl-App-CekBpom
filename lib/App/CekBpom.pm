package App::CekBpom;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Exporter qw(import);
our @EXPORT_OK = qw(cek_bpom);

our %SPEC;

my $url_prefix = "https://cekbpom.pom.go.id/index.php";

my %known_search_types = (
    # name => [number in bpom website's form, shortcut alias if any]
    nomor_registrasi => [0],
    nama_produk => [1, 'n'],
    merk => [2, 'm'],
    jumlah_dan_kemasan => [3],
    bentuk_sediaan => [4],
    komposisi => [5],
    nama_pendaftar => [6, 'p'],
    npwp_pendaftar => [7],
);

$SPEC{cek_bpom} = {
    v => 1.1,
    summary => 'Search BPOM products via https://cekbpom.pom.go.id/',
    description => <<'_',

Uses <pm:LWP::UserAgent::Plugin> so you can add retry, caching, or additional
HTTP client behavior by setting `LWP_USERAGENT_PLUGINS` environment variable.

_
    args => {
        search_types => {
            'x.name.is_plural' => 1,
            'x.name.singular' => 'search_type',
            summary => 'Select what field(s) to search against',
            schema => ['array*', of=>['str*', in=>[sort keys %known_search_types]]],
            cmdline_aliases => {
                t=>{},
                (
                    map {
                        my $t = $_;
                        my @aliases;
                        push @aliases, ($t => {is_flag=>1, summary=>"Shortcut for --search-type=$t", code=>sub { $_[0]{search_types} //= []; push @{ $_[0]{search_types} }, $t }});
                        my $shortcut = $known_search_types{$t}[1];
                        if (defined $shortcut) {
                            push @aliases, ($shortcut => {is_flag=>1, summary=>"Shortcut for --search-type=$t", code=>sub { $_[0]{search_types} //= []; push @{ $_[0]{search_types} }, $t }});
                        }
                        @aliases;
                    } keys %known_search_types,
                ),
            },
            description => <<'_',

By default, if not specified, will search against product name ("nama_produk")
and brand ("merk"). If you specify multiple times, it will search against all
those types, e.g.:

    --search-type nama_produk --search-type nama_pendaftar

or:

    --nama-produk --nama-pendaftar

_
        },
        queries => {
            'x.name.is_plural' => 1,
            'x.name.singular' => 'query',
            schema =>  ['array*', of=>'str*'],
            req => 1,
            pos => 0,
            slurpy => 1,
        },
    },
    examples => [
        {
            summary => 'By default search against name (nama_produk) and brand (merk)',
            argv => ["hichew", "hi-chew", "hi chew"],
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Adding --trace will show query details, --format html+datatables is convenient to see/search/sort results in browser',
            src => "[[prog]] hichew hi-chew 'hi chew' --trace --format html+datatables",
            src_plang => "bash",
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
};
sub cek_bpom {
    require HTTP::CookieJar::LWP;
    require LWP::UserAgent::Plugin;

    my %args = @_;
    defined(my $queries = $args{queries}) or return [400, "Please specify queries"];
    my $search_types = $args{search_types} // ['nama_produk', 'merk'];

    my $jar = HTTP::CookieJar::LWP->new;
    my $ua = LWP::UserAgent::Plugin->new(
        cookie_jar => $jar,
    );

    # first get the front page so we get the session ID
    log_trace "Requesting cekbpom front page ...";
    my $res = $ua->get($url_prefix);
    unless ($res->is_success) {
        return [$res->code, "Can't get front page ($url_prefix): ".$res->message];
    }
    my $ct = $res->content;
    unless ($ct =~ m!/home/produk/(\w{26})"!) {
        return [543, "Can't extract session ID from front page"];
    }
    my $session_id = $1;

    my %reg_ids;
    my @all_rows;

  QUERY:
    for my $query (@$queries) {
      SEARCH_TYPE:
        for my $search_type (@$search_types) {
            my $search_type_num = $known_search_types{$search_type}[0];
            unless (defined $search_type_num) {
                return [400, "Unknown search_type '$search_type'"];
            }

            require URI::Escape;
            my $query_enc = URI::Escape::uri_escape($query);

            my @rows;
            my $page_num = 0;
            my $num_results = 100;
            my ($result_start, $result_end);
            while (1) {
                log_trace "Querying cekbpom ($search_type=$query, $num_results result(s)) ...";
                $res = $ua->get("$url_prefix/home/produk/$session_id/all/row/$num_results/page/$page_num/order/4/DESC/search/$search_type_num/$query_enc");
                unless ($res->is_success) {
                    return [$res->code, "Can't get result page: ".$res->message];
                }
                my $ct = $res->content;
                unless ($ct =~ m!(\d+) - (\d+) Dari (\d+)!) {
                    return [543, "Can't find signature in result page"];
                }
                ($result_start, $result_end, $num_results) = ($1, $2, $3);

                if ($result_end < $num_results && $result_end < 5000) {
                    redo;
                }

                if ($ENV{CEK_BPOM_TRACE}) {
                    log_trace $ct;
                }

                while ($ct =~ m!
                                   <tr\stitle.+?\surldetil="/(?P<reg_id>[^"]+)">
                                   <td[^>]*>(?P<nomor_registrasi>[^<]+)(?:<div>Terbit: (?P<tanggal_terbit>[^<]+))?</div></td>
                                   <td[^>]*>(?P<nama>[^<]+)<div>Merk: (?P<merk>[^<]+)<br>Kemasan: (?P<kemasan>[^<]+)</div></td>
                                   <td[^>]*>(?P<pendaftar>[^<]+)<div>(?P<kota_pendaftar>[^<]+)</div></td>
                               !sgx) {
                    my $row = {%+};
                    for (qw/kemasan/) { $row->{$_} =~ s/\R+//g }
                    push @rows, $row;
                }
                last;
            }

            if (@rows < $num_results) {
                # XXX should've been a fatal error
                log_warn "Some results cannot be parsed (only got %d out of %d)", scalar(@rows), $num_results;
            } else {
                log_trace "Got $num_results result(s)";
            }

            # add to final result
            for (@rows) {
                push @all_rows, $_ unless $reg_ids{ $_->{reg_id} }++;
            }
        } # for SEARCH_TYPE
    } # for QUERY

    if (@$search_types > 1 || @$queries > 1) {
        log_trace "Got a total of %d result(s)", scalar(@all_rows);
    }

    my %resmeta;
    $resmeta{'table.fields'} = [qw/reg_id nomor_registrasi tanggal_terbit nama merk kemasan pendaftar kota_pendaftar/];

    [200, "OK", \@all_rows, \%resmeta];
}

1;
# ABSTRACT: Check BPOM products via the command-line (CLI interface for cekbpom.pom.go.id)

=head1 DESCRIPTION

See included script L<cek-bpom>.


=head1 SEE ALSO

L<https://cekbpom.pom.go.id/>

=cut
