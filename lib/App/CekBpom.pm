package App::CekBpom;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;
use Log::ger;

use Time::HiRes qw(time);

use Exporter qw(import);
our @EXPORT_OK = qw(cek_bpom_products);

our %SPEC;

my $url_prefix = "https://cekbpom.pom.go.id/index.php";

my %known_search_types = (
    # name => [number in bpom website's form, shortcut alias if any]
    nomor_registrasi => [0],
    nama_produk => [1, 'p'],
    merk => [2, 'm'],
    jumlah_dan_kemasan => [3],
    bentuk_sediaan => [4],
    komposisi => [5],
    nama_pendaftar => [6, 'P'],
    npwp_pendaftar => [7],
);

sub _encode {
    my $str = shift;
    $str =~ s/[^A-Za-z_0-9-]+/-/g;
    $str;
}

$SPEC{cek_bpom_products} = {
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

Note: the mobile app version allows you to search for products by original
manufacturer ("produsen") as well, which is not available in the website
version. The website allows you to search for producers ("sarana") by
name/address/city/province/country, though, and lets you view what products are
registered for that producer.

This utility will allow you to fetch the detail of each product, including
manufacturer (see `--get-product-detail` option).

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
        get_product_detail => {
            schema => 'bool*',
            description => <<'_',

For each product (search result), fetch the detail. This currently fetches the
manufacturer ("produsen"), which is not displayed by the search result page.
Note that this requires a separate HTTP request for each product so can
potentially take a long time and might get you banned. Suggestions include: (1)
searching without this option first to find out the number of results, then
search again with this option if you need it; (2) use
<pm:LWP::UserAgent::Plugin::Delay> to throttle your HTTP requests.

_
        },
        note => {
            summary => 'Add note',
            schema => 'str*',
            description => <<'_',

This will not be sent as queries, but will be added to the log file if log file
is specified, as well as added to the result dump file name, in encoded form.

_
            tags => ['category:logging'],
        },
        query_log_file => {
            summary => 'Log queries to log file',
            schema => 'filename*',
            description => <<'_',

If specified, each invocation of this utility will be logged into a line in the
specified file path, in TSV format. Tab character in the query will be converted
into 4 spaces, to avoid clash with the use of Tab as field separator.

For example, this invocation:

    % cek-bpom-products "minuman susu fermentasi" yakult --query-log-file /some/path.txt

Sample log line:

    time:2020-10-22T01:02:03.000Z    queries:minuman susu fermentasi,yakult    search_types:merk,nama_produk    num_results:51    duration:3.402

_
            tags => ['category:logging'],
        },
        result_dump_dir => {
            summary => 'Dump result to directory',
            schema => 'dirname*',
            description => <<'_',

If specified, will dump full enveloped result to a file in specified directory
path, in JSON format. The JSON formatting makes it easy to grep each row. The
file will be named
`cek-bpom-products-result.<encoded-timestamp>.<search-types-encoded>.<queries-encoded>(.<note-encoded>)?.json`.
The encoded timestamp is ISO 8601 format with colon replaced by underscore. The
encoded query will replace all every group of "unsafe" characters in query with
a single dash. The same goes with encoded note, which comes from the `note`
argument. For example, this invocation:

    % cek-bpom-products "minuman susu fermentasi" yakult --note "some note"

will result in a result dump file name like:
`cek-bpom-products-result.2020-10-22T01_02_03.000Z.merk-nama_produk.minuman-susu-fermentasi-yakult.some-note.json`.

_
            tags => ['category:logging'],
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
sub cek_bpom_products {
    require HTTP::CookieJar::LWP;
    require LWP::UserAgent::Plugin;

    my $time_start = time();

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

    my $time_before_query = time();
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
                                   <td[^>]*>\s* (?P<nomor_registrasi>[^<]+?)\s*   (?:<div>Terbit:(?P<tanggal_terbit>[^<]+?))?\s*    </div></td>
                                   <td[^>]*>\s* (?P<nama>[^<]+?)\s*<div>Merk:\s*  (?P<merk>[^<]+)<br>Kemasan:(?P<kemasan>[^<]+?)\s* </div></td>
                                   <td[^>]*>\s* (?P<pendaftar>[^<]+?)\s*<div>\s*  (?P<kota_pendaftar>[^<]+?)\s*                     </div></td>
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
    my $time_after_query = time();

    if (@$search_types > 1 || @$queries > 1) {
        log_trace "Got a total of %d result(s)", scalar(@all_rows);
    }

  GET_PRODUCT_DETAIL: {
        last unless $args{get_product_detail};
        my $i = 0;
        for my $row (@all_rows) {
            $i++;
            log_trace "[%d/%d] Getting product detail for %s (%s) ...",
                $i, scalar(@all_rows), $row->{reg_id}, $row->{nama};
            my $res = $ua->get("$url_prefix/home/detil/$session_id/produk/$row->{reg_id}");
            unless ($res->is_success) {
                log_warn "Cannot get product detail for $row->{reg_id} ($row->{nama}), skipped";
                next;
            }
            my $ct = $res->content;
            $ct =~ m!<td[^>]*>Diproduksi Oleh</td><td><a href="[^"]+sarana/[^"]+/id/([^"]+)"[^>]*>\s*([^<]+?)\s*</a> - ([^<]+?)\s*</td>! or do {
                log_warn "Cannot get manufacturer detail for $row->{reg_id} ($row->{nama}), skipped";
            };
            $row->{sarana_id} = $1;
            $row->{sarana_nama} = $2;
            $row->{sarana_negara} = $3;
            my $session_id = $1;
        }
    } # GET_PRODUCT_DETAIL

    my %resmeta;
    $resmeta{'table.fields'} = [qw/reg_id nomor_registrasi tanggal_terbit nama merk kemasan pendaftar kota_pendaftar sarana_id sarana_nama sarana_negara/];

    unless (@all_rows) {
        $resmeta{'cmdline.result'} = "No results found for ".join(", ", @$queries).
            " (search types: ".join(", ", @$search_types).". Perhaps try other spelling variations or additional search types.";
    }

  LOG_QUERY: {
        last unless defined(my $path = $args{query_log_file});
        require Date::Format::ISO8601;

        my %fields = (
            what => 'products',
            time => Date::Format::ISO8601::gmtime_to_iso8601_datetime({second_precision=>0}, $time_start),
            queries => join(",", @$queries),
            search_types => join(",", @$search_types),
            opt_get_product_detail => $args{get_product_detail} ? 1:0,
            num_results => scalar @all_rows,
            (note => $args{note}) x !!(exists $args{note}),
            duration => sprintf("%0.3f", $time_after_query-$time_before_query),
            cek_bpom_version => ${__PACKAGE__.'::VERSION'} || 'dev',
        );
        open my $fh, ">>", $path or do {
            log_error "Can't open query log file '$path': $!, skipped logging query";
            last LOG_QUERY;
        };
        my $log_line = join("\t", map { my $key=$_; my $val=$fields{$key}; $val=~s/\R/ /g; $val=~s/\t/    /g; "$key:$val" } sort keys %fields);
        log_trace "Logging query: $log_line";
        print $fh $log_line, "\n";
        close $fh or do {
            log_error "Can't write log to query log file '$path': $!, ignoring";
        };
    }

    my $envres = [200, "OK", \@all_rows, \%resmeta];

  DUMP_RESULT: {
        last unless defined(my $dir = $args{result_dump_dir});
        require JSON::Encode::TableData;

        -d $dir or do {
            log_error "Result dump dir '$dir' does not exist or not a dir, skipped dumping result";
            last DUMP_RESULT;
        };
        my $filename = sprintf(
            "cek-bpom-products-result.%s.%s.%s%s.json",
            Date::Format::ISO8601::gmtime_to_iso8601_datetime({second_precision=>0, time_sep=>"_"}, $time_start),
            _encode(join ",", @$search_types),
            _encode(join ",", @$queries),
            defined $args{note} ? "."._encode($args{note}) : "",
        );
        log_trace "Dumping result to $dir/$filename ...";
        open my $fh, ">", "$dir/$filename" or do {
            log_error "Can't open '$dir/$filename': $!, skipped dumping result";
            last DUMP_RESULT;
        };
        print $fh JSON::Encode::TableData::encode_json($envres);
        close $fh or do {
            log_error "Can't write '$dir/$filename': $!, ignoring";
        };
    }

    $envres;
}

1;
# ABSTRACT: Check BPOM products/manufacturers ("sarana") via the command-line (CLI interface for cekbpom.pom.go.id)

=head1 DESCRIPTION

See included script L<cek-bpom-products> and L<cek-bpom-manufacturers>.


=head1 SEE ALSO

L<https://cekbpom.pom.go.id/>

=cut
