use JSON::Fast::Hyper:ver<0.0.3>:auth<zef:lizmat>;
use Identity::Utils:ver<0.0.9>:auth<zef:lizmat>;
use Rakudo::CORE::META:auth<zef:lizmat>;
use Map::Match:ver<0.0.3>:auth<zef:lizmat>;

constant %meta-url =
  p6c  => "https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/p6c1.json",
  cpan => "https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/cpan1.json",
  fez  => "https://360.zef.pm/",
  rea  => "https://raw.githubusercontent.com/Raku/REA/main/META.json",
;

my $store := ($*HOME // $*TMPDIR).add(".zef").add("store");

class Ecosystem:ver<0.0.14>:auth<zef:lizmat> {
    has IO::Path $.IO;
    has Str $.meta-url;
    has Int $.stale-period is built(:bind) = 86400;
    has str $.ecosystem is built(False);
    has str $.meta      is built(False);
    has %.identities    is built(False);
    has %.distro-names  is built(False);
    has %.use-targets   is built(False);
    has $!matches;
    has $!reverse-dependencies;
    has $!all-unresolvable-dependencies;
    has $!current-unresolvable-dependencies;
    has $!river;
    has Date $!least-recent-release;
    has Date $!most-recent-release;
    has Lock $!meta-lock;

    method TWEAK(Str:D :$ecosystem = 'rea') {
        without $!meta-url {
            if %meta-url{$ecosystem} -> $url {
                $!meta-url := $url;
                $!IO       := $store.add($ecosystem).add("$ecosystem.json");
                $!ecosystem = $ecosystem;
            }
            else {
                die "Unknown ecosystem: $ecosystem";
            }
        }

        $!IO
          ?? mkdir($!IO.parent)
          !! die "Must specify IO with a specified meta-url";

        $!meta-lock := Lock.new;
        self!stale
          ?? self!update-meta-from-URL
          !! self!update-meta-from-json($!IO.slurp)
    }

    method !stale() {
        $!IO.e
          ?? $!meta-url && now - $!IO.modified > $!stale-period
          !! True
    }

    method !update-meta-from-URL() {
        $!meta-lock.protect: {
            my $proc := run 'curl', $!meta-url, :out, :!err;
            self!update-meta-from-json: $proc.out.slurp;
            $!IO.spurt: $!meta;
        }
    }

    my sub add-identity(%hash, str $key, str $identity) {
        if %hash{$key} -> @identities {
            @identities.push($identity)
        }
        else {
            %hash{$key} := (my str @ = $identity);
        }
    }

    my sub sort-identities(@identities) {
        @identities.sort({ version($_) // "" }).reverse.sort: {
            short-name($_).fc
        }
    }

    my sub sort-identities-of-hash(%hash) {
        for %hash.kv -> $key, @identities {
            %hash{$key} := my str @ =
              @identities.unique.sort(&version).reverse.sort(&short-name);
        }
    }

    my constant @extensions = <.tar.gz .tgz .zip>;
    my sub no-extension(Str:D $string) {
        return $string.chop(.chars) if $string.ends-with($_) for @extensions;
    }
    my sub extension(Str:D $string) {
        @extensions.first: { $string.ends-with($_) }
    }
    my sub determine-base($domain) {
        $domain
          ?? $domain eq 'raw.githubusercontent.com' | 'github.com'
            ?? 'github'
            !! $domain eq 'gitlab.com'
              ?? 'gitlab'
              !! Nil
          !! Nil
    }

    # Version encoded in path has priority over version in META because
    # PAUSE would not allow uploads of the same version encoded in the
    # distribution name, but it *would* allow uploads with a non-matching
    # version in the META.  Also make sure we skip any "v" in the version
    # string.
    method !elide-identity-cpan(str $name, %meta) {
# http://www.cpan.org/authors/id/Y/YN/YNOTO/Perl6/json-path-0.1.tar.gz
# git://github.com/Tux/CSV.git
        if %meta<source-url> -> $URL {
            my @parts = $URL.split('/');
            my $auth := %meta<auth> :=
              'cpan:' ~ @parts[2] ne 'www.cpan.org'
                ?? @parts[3].uc
                !! @parts[7];

            # Determine version from filename
            my $nept := no-extension(@parts.tail);
            with $nept && $nept.rindex('-') -> $index {
                my $ver := $nept.substr($index + 1);
                $ver := $ver.substr(1)
                  if $ver.starts-with('v');

                # keep version in meta if strange in filename
                $ver.contains(/ <-[\d \.]> /)
                  ?? ($ver := %meta<version>)
                  !! (%meta<version> := $ver);

                %meta<dist> :=
                  build $name, :$ver, :$auth, :api(%meta<api>)
            }

            # Assume version in meta is correct
            elsif %meta<version> -> $ver {
                %meta<dist> :=
                  build $name, :$ver, :$auth, :api(%meta<api>)
            }
        }
    }

    # Heuristics for determining identity of a distribution on p6c
    # that does not provide an identity directly
    method !elide-identity-p6c(str $name, %meta) {
        if !$name.contains(' ')
          && %meta<version> -> $ver {
            if %meta<source-url> -> $URL {
                my @parts = $URL.split('/');
                if determine-base(@parts[2]) -> $base {
                    my $user := @parts[3];
                    unless $user eq 'AlexDaniel'
                      and @parts.tail.contains('foo') {
                        my $auth := %meta<auth> := "$base:$user";
                        %meta<dist> :=
                          build $name, :$ver, :$auth, :api(%meta<api>)
                    }
                }
            }
        }
    }

    method !elide-identity(str $name, %meta) {
        $!ecosystem eq 'cpan'
          ?? self!elide-identity-cpan($name, %meta)
          !! $!ecosystem eq 'p6c'
            ?? self!elide-identity-p6c($name, %meta)
            !! die "Cannot elide identity of '$name' in '$!ecosystem'";
    }

    method !update-meta-from-json($!meta --> Nil) {
        my %identities;
        my %distro-names;
        my %use-targets;
        my %descriptions;

        with %Rakudo::CORE::META -> %meta {
            my $name     := %meta<name>;
            my $identity := %meta<dist>;

            %identities{$identity} := %meta.Map;
            add-identity %distro-names, $name, $identity;
            add-identity %use-targets,  $_,    $identity
              for %meta<provides>.keys;
        }

        for from-json($!meta, :immutable) -> %meta {
            if %meta<name> -> $name {
                if %meta<dist>
                  // self!elide-identity($name, %meta) -> $identity {
                    %identities{$identity} := %meta;
                    add-identity %distro-names, $name, $identity;

                    if %meta<provides> -> %provides {
                        add-identity %use-targets, $_, $identity
                          for %provides.keys;
                    }
                }
            }
        }

        if $!ecosystem ne 'rea' {
            for %distro-names, %use-targets -> %hash {
                sort-identities-of-hash %hash;
            }
        }

        %!identities   := %identities.Map;
        %!distro-names := %distro-names.Map;
        %!use-targets  := %use-targets.Map;

        # reset all dependent data structures
        $!least-recent-release = $!most-recent-release = Nil;
        $!matches
          := $!reverse-dependencies
          := $!all-unresolvable-dependencies
          := $!current-unresolvable-dependencies
          := $!river
          := Any;
    }

    my sub filter(@identities, $ver, $auth, $api, $from) {
        my $auth-needle := $auth ?? ":auth<$auth>" !! "";
        my $api-needle  := $api && $api ne '0'
          ?? ":api<$api>"
          !! "";
        my $from-needle := $from && !($from eq 'Perl6' | 'Raku')
          ?? ":from<$from>"
          !! "";
        my $version;
        my &ver-matches;
        if $ver {
            if $ver eq '*' {
                &ver-matches = { ver($_) eq "*" }
            }
            else {
                $version := $ver.Version;  # could be a noop
                &ver-matches = $version.plus || $version.whatever
                  ?? { version($_) ~~ $version }
                  !! { version($_) == $version }
            }
        }

        @identities.grep: {
            (!$from-needle || .contains($from-needle))
              &&
            (!$api-needle  || .contains($api-needle))
              && 
            (!$auth-needle || .contains($auth-needle))
              &&
            (!&ver-matches || ver-matches($_))
        }
    }

    method find-identities(Ecosystem:D:
      Any:D $needle = "", :$ver, :$auth, :$api, :$from, :$all
    ) {
        if filter $needle
                    ?? self.matches{$needle}.map(*.Slip).unique
                    !! %!identities.keys,
                  $ver, $auth, $api, $from -> @identities {
            my %seen;
            sort-identities $all
              ?? @identities
              !! @identities.map: { $_ unless %seen{short-name($_)}++ }
        }
    }

    method find-distro-names(Ecosystem:D: Any:D $needle = "", *%_) {
        my &accepts := $needle ~~ Regex
          ?? -> $name { $needle.ACCEPTS($name) }
          !! $needle
            ?? -> $name { $name.contains($needle, :i, :m) }
            !! -> $name { True }

        my %seen;
        self.find-identities($needle, |%_, :all).map: {
            with %!identities{$_}<name> -> $name {
                $name if accepts($name) && not %seen{$name}++
            }
        }
    }

    method find-use-targets(Ecosystem:D: Any:D $needle = "", *%_) {
        my &accepts := $needle ~~ Regex
          ?? -> $use-target { $needle.ACCEPTS($use-target) }
          !! $needle
            ?? -> $use-target { $use-target.contains($needle, :i, :m) }
            !! -> $use-target { True }

        my %seen;
        self.find-identities($needle, |%_, :all).map: {
            with %!identities{$_}<provides> -> %provides {
                %provides.keys.first( -> $use-target {
                    accepts($use-target) && not %seen{$use-target}++
                }) // Empty
            }
        }
    }

    method identity-url(Ecosystem:D: str $identity) {
        %!identities{$identity}<source-url>
    }

    method identity-release-Date(Ecosystem:D: str $identity) {
        %!identities{$identity}<release-date>.Date
    }
    method identity-release-yyyy-mm-dd(Ecosystem:D: str $identity) {
        %!identities{$identity}<release-date>
    }
    method identity-dependencies(Ecosystem:D: str $identity, :$all) {
        if %!identities{$identity} -> %meta {
            ($all
              ?? self!dependencies($identity).unique
              !! dependencies-from-depends(%meta<depends>)
            ).sort(*.fc)
        }
    }

    my sub identities2distros(@identities) {
        my %seen;
        @identities.map: {
            if short-name($_) -> $name {
                $name unless %seen{$name}++
            }
        }
    }

    method distros-of-use-target(str $target) {
        if %!use-targets{$target} -> @identities {
            identities2distros(@identities)
        }
    }

    method !minmax-release-dates(--> Nil) {
        $!meta-lock.protect: {
            my $range := %!identities.values.map( -> %_ {
                $_ with %_<release-date>
            }).minmax;
            if $range.min ~~ Str {
                $!least-recent-release := $range.min.Date;
                $!most-recent-release  := $range.max.Date;
            }
        }
    }

    method least-recent-release() {
        $!least-recent-release
          // self!minmax-release-dates
          // $!least-recent-release

    }

    method most-recent-release() {
        $!most-recent-release
          // self!minmax-release-dates
          // $!most-recent-release
    }

    method update() {
        $!meta-url
          ?? self!update-meta-from-URL
          !! self!update-meta-from-json  # assumes it was changed
    }

    my sub as-short-name(str $needle) {
        $needle eq short-name($needle)
          ?? Nil
          !! short-name($needle)
    }

    my multi sub dependencies-from-depends(Any:U $) { Empty }
    my multi sub dependencies-from-depends(Any:D $depends) {
        if $depends ~~ Positional {
            $depends
        }
        elsif $depends ~~ Associative {
            if $depends<runtime><requires> -> $requires {
                $requires.map: {
                    $_ ~~ Associative
                      ?? build .<name>, :ver(.<ver>), :auth(.<auth>),
                           :api(.<api>), :from(.<from(>)
                      !! $_
                } if $requires ~~ Positional;
            }
        }
        elsif $depends ~~ Str {
            $depends
        }
    }

    method !dependencies(str $needle) {
        if %!identities{$needle} -> %meta {
            dependencies-from-depends(%meta<depends>).map( -> str $found {
                ($found, self!dependencies($found).Slip).Slip
                  if $found ne $needle
            }).Slip
        }
        elsif %!use-targets{$needle} -> @identities {
            self!dependencies(@identities.head)
        }
        elsif %!distro-names{$needle} -> @identities {
            self!dependencies(@identities.head)
        }
        elsif as-short-name($needle) -> $short-name {
            self!dependencies($short-name)
        }
    }

    method dependencies(Ecosystem:D: str $needle) {
        self!dependencies($needle).unique.sort(*.fc)
    }

    method resolve(Ecosystem:D:
      str $needle,
         :$ver  = ver($needle),
         :$auth = auth($needle),
         :$api  = api($needle),
         :$from = from($needle),
    ) {
        my str $short-name = short-name($needle);
        if %!distro-names{$short-name}
          // %!use-targets{$short-name} -> @identities {
            filter(@identities, $ver, $auth, $api, $from).head
        }
        else {
            Nil
        }
    }

    method reverse-dependencies(Ecosystem:D:) {
        $!reverse-dependencies // $!meta-lock.protect: {

            # done if other thread already updated
            return $!reverse-dependencies if $!reverse-dependencies;

            my %reverse-dependencies;
            for %!identities
              .keys
              .race
              .map( -> $identity {
                self.dependencies($identity).map({$_ => $identity }).Slip
            }) {
                if %reverse-dependencies{.key} -> @found {
                    @found.push: .value;
                }
                else {
                    %reverse-dependencies{.key} := my str @ = .value;
                }
            }

            sort-identities-of-hash %reverse-dependencies;

            $!reverse-dependencies := %reverse-dependencies;
        }
    }

    method reverse-dependencies-for-short-name(Ecosystem:D: str $short-name) {
        self.reverse-dependencies.race.map({
            if short-name(.key) eq $short-name {
                .value.map(*.&short-name).squish.Slip
            }
        }).unique
    }

    method most-recent-identity(Ecosystem:D: str $needle) {
        my str $short-name = short-name($needle);
        if %!distro-names{$short-name}
          // %!use-targets{$short-name} -> @identities {
            @identities.grep({short-name($_) eq $short-name}).head // $needle
        }
        else {
            Nil
        }
    }

    method !all-unresolvable-dependencies() {
        $!all-unresolvable-dependencies // $!meta-lock.protect: {
            $!all-unresolvable-dependencies // do {
                my %id := %!identities;
                my %unr is Map = self.reverse-dependencies.grep: {
                    %id{.key}:!exists
                }
                $!all-unresolvable-dependencies := %unr
            }
        }
    }

    method !current-unresolvable-dependencies() {
        $!current-unresolvable-dependencies // $!meta-lock.protect: {
            $!current-unresolvable-dependencies // do {
                my %unr is Map = self!all-unresolvable-dependencies.map: {
                    if .value.map({
                        self.most-recent-identity($_)
                    }).unique -> @identities {
                        .key => (my str @ = @identities)
                    }
                }
                $!current-unresolvable-dependencies := %unr
            }
        }
    }

    method unresolvable-dependencies(Ecosystem:D: :$all) {
        $all
          ?? self!all-unresolvable-dependencies
          !! self!current-unresolvable-dependencies
    }

    method matches(Ecosystem:D:) {
        $!matches // $!meta-lock.protect: {
            $!matches // do {
                my %matches;
                for %!distro-names, %!use-targets -> %hash {
                    for %hash.kv -> str $key, @additional {
                        if %matches{$key} -> @strings {
                            @strings.append: @additional
                        }
                        else {
                            %matches{$key} := (my str @ = @additional);
                        }
                    }
                    for %!identities.kv -> $identity, %meta {
                        if %meta<description> -> $text {
                            if %matches{$identity} -> @strings {
                                @strings.push: $text
                            }
                            else {
                                %matches{$identity} := (my str @ = $text);
                            }
                        }
                    }
                }
                $!matches := Map::Match.new: %matches;
            }
        }
    }

    method river(Ecosystem:D:) {
        $!river // $!meta-lock.protect: {
            $!river // do {
                my %river;
                for %!identities.keys.race.map( -> $identity {
                    my $short-name := short-name $identity;
                    self.dependencies($identity).map({
                        short-name($_) unless is-pinned($_)
                    }).squish.map({
                        $_ => $short-name
                    }).Slip
                }) -> (:key($dependency), :value($dependee)) {
                    with %river{$dependency} {
                        .push: $dependee;
                    }
                    else {
                        %river{$dependency} := my str @ = $dependee;
                    }
                }
                for %river.kv -> $short-name, @dependees {
                    %river{$short-name} :=
                      my str @ = @dependees.unique.sort(*.fc)
                }

                $!river := %river.Map
            }
        }
    }

    method unversioned-distro-names(Ecosystem:D:) {
        %!identities.keys.grep({
            version($_).whatever
              && version(self.resolve(without-ver($_))).whatever
        }).sort(*.fc)
    }

    # Give CLI access to rendering using whatever JSON::Fast we have
    method to-json(Ecosystem: \data) is implementation-detail {
        use JSON::Fast;
        to-json data, :sorted-keys
    }

    method dependencies-from-meta(Ecosystem: %meta) {
        dependencies-from-depends(%meta<depends>).Slip
    }

    method sort-identities(Ecosystem: @identities) {
        sort-identities @identities
    }
}

=begin pod

=head1 NAME

Ecosystem - Accessing a Raku Ecosystem

=head1 SYNOPSIS

=begin code :lang<raku>

use Ecosystem;

my $eco = Ecosystem.new;  # access the REA ecosystem

say "Ecosystem has $eco.identities.elems() identities:";
.say for $eco.identities.keys.sort;

=end code

=head1 DESCRIPTION

Ecosystem provides the basic logic to accessing a Raku Ecosystem,
defaulting to the Raku Ecosystem Archive, a place where (almost) every
distribution ever available in the Raku Ecosystem, can be obtained
even after it has been removed (specifically in the case of the old
ecosystem master list and the distributions kept on CPAN).

=head1 COMMAND LINE INTERFACE

The C<ecosystem> script provides a direct way to interrogate the contents
of a given eco-system.  Please see the usage information of the script
for further information (use C<--help> for extensive help).

=head1 CONSTRUCTOR ARGUMENTS

=head2 ecosystem

=begin code :lang<raku>

my $eco = Ecosystem.new(:ecosystem<fez>);

=end code

The C<ecosystem> named argument is string that indicates which ecosystem
(content-storage) should be used: it basically is a preset for the
C<meta-url> and C<IO> arguments.  The following names are recognized:

=item p6c  the original content storage / ecosystem
=item cpan the content storage that uses CPAN
=item fez  the zef (fez) ecosystem
=item rea  the Raku Ecosystem Archive (default)

If this argument is not specified, then at least the C<IO> named argument
must be specified.

=head2 IO

=begin code :lang<raku>

my $eco = Ecosystem.new(IO => "path".IO);

=end code

The C<IO> named argument specifies the path of the file that contains
/ will contain the META information.  If not specified, will default
to whatever can be determined from the other arguments.

=head2 meta-url

=begin code :lang<raku>

my $eco = Ecosystem.new(meta-url => "https://foo.bar/META.json");

=end code

The C<meta-url> named argument specifies the URL that should be used to
obtain the META information if it is not available locally yet, or if
it has been determined to be stale.  Will default to whatever can be
determined from the other arguments.  If specified, then the C<IO>
arguments B<must> also be specified to store the meta information in.

=head2 stale-period

=begin code :lang<raku>

my $eco = Ecosystem.new(stale-period => 3600);

=end code

The C<stale-period> named argument specifies the number of seconds
after which the meta information is considered to be stale and needs
updating using the C<meta-url>.  Defaults to C<86400>, aka 1 day.

=head1 CLASS METHODS

=head2 dependencies-from-meta

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.dependencies-from-meta(from-json $io.slurp);

=end code

The C<dependencies-from-meta> class method returns the list of C<use-targets>
as specified in the C<depends> field of the given hash with meta information.

=head2 sort-identities

=begin code :lang<raku>

.say for Ecosystem.sort-identities(@identities);

=end code

The C<sort-identities> class method sorts the given identities with
the highest version first, and then by the C<short-name> of the
identity.

=head1 INSTANCE METHODS

=head2 dependencies

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.dependencies("Ecosystem");

=end code

The C<dependencies> instance method returns a sorted list of all
C<use-target>s (either directly or recursively) for an C<identity>,
C<use-target> or C<distro-name>.

=head2 distro-names

=begin code :lang<raku>

my $eco = Ecosystem.new;
say "Found $eco.distro-names.elems() differently named distributions";

=end code

The C<distro-names> instance method returns a C<Map> keyed on distribution
name, with a sorted list of the identities that have that distribution
name (sorted by short-name, latest version first).

=head2 distros-of-use-target

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.distros-of-use-target($target);

=end code

The C<distro-of-use-target> instance method the names of the distributions
that provide the given use target.

=head2 ecosystem

=begin code :lang<raku>

my $eco = Ecosystem.new;
say "The ecosystem is $_" with $eco.ecosystem;

=end code

The C<ecosystem> instance method returns the value (implicitely) specified
with the C<:ecosystem> named argument.

=head2 find-distro-names

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.find-distro-names: / JSON /;

.say for $eco.find-distro-names: :auth<zef:lizmat>;

=end code

The C<find-distro-names> instance method returns the distribution names
that match the optional given string or regular expression, potentially
filtered by a C<:ver>, C<:auth>, C<:api> and/or C<:from> value.

=head2 find-identities

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.find-identities: / Utils /, :ver<0.0.3+>, :auth<zef:lizmat>;

.say for $eco.find-identities: :auth<zef:lizmat>, :all;

=end code

The C<find-identities> method returns identities (sorted by short-name,
latest version first) that match the optional given string or regular
expression, potentially filtered by C<:ver>, C<:auth>, C<:api> and/or
C<:from> value.

The specified string is looked up / regular expression is matched in
the distribution names, the use-targets and the descriptions of the
distributions.

By default, only the identity with the highest C<:ver> value will be
returned: a C<:all> flag can be specified to return B<all> possible
identities.

=head2 find-use-targets

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.find-use-targets: / JSON /;

.say for $eco.find-use-targets: :auth<zef:lizmat>;

=end code

The C<find-use-targets> instance method returns the strings that can be
used in a C<use> command that match the optional given string or regular
expression, potentially filtered by a C<:ver>, C<:auth>, C<:api> and/or
C<:from> value.

=head2 identities

=begin code :lang<raku>

my $eco = Ecosystem.new;
my %identities := $eco.identities;
say "Found %identities.elems() identities";

=end code

The C<identities> instance method returns a C<Map> keyed on identity string,
with a C<Map> of the META information of that identity as the value.

=head2 identity-dependencies

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.identity-dependencies($identity);

.say for $eco.identity-dependencies($identity, :all);

=end code

The C<identity-dependencies> instance method returns a sorted list of the
dependencies of the given B<identity> string, if any.  Takes an optional
C<:all> named to also return any dependencies of the initial dependencies,
recursively.

=head2 identity-release-Date

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.identity-release-Date($identity);

=end code

The C<identity-release-Date> instance method returns the C<Date> when the
the distribution of the given identity string was released, or C<Nil> if
either the identity could not be found, or if there is no release date
information available.

=head2 identity-release-yyyy-mm-dd

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.identity-release-yyyy-mm-dd($identity);

=end code

The C<identity-release-yyyy-mm-dd> instance method returns a C<Str> in
YYYY-MM-DD format of when the the distribution of the given identity string
was released, or C<Nil> if either the identity could not be found, or if
there is no release date information available.

=head2 identity-url

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.identity-url($identity);

=end code

The C<identity-url> instance method returns the C<URL> of the distribution
file associated with the given identity string, or C<Nil>.

=head2 IO

=begin code :lang<raku>

my $eco = Ecosystem.new(:IO("foobar.json").IO);
say $eco.IO;  # "foobar.json".IO

=end code

The C<IO> instance method returns the C<IO::Path> object of the file where
the local copy of the META data lives.

=head2 least-recent-release

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.least-recent-release;

=end code

The C<least-recent-release> instancemethod returns the C<Date> of the
least recent release in the ecosystem, if any.

=head2 matches

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.matches{ / Utils / };

=end code

The C<matches> instance method returns a
L<Map::Match|https://raku.land/zef:lizmat/Map::Match> with the
string that caused addition of an identity as the key, and a
sorted list of the identities that either matched the distribution
name or the description (sorted by short-name, latest version first).
It is basically the workhorse of the L<find-identities|#find-identities>
method.

=head2 meta

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.meta;  # ...

=end code

The C<meta> instance method returns the JSON representation of the
META data.

=head2 meta-url

=begin code :lang<raku>

my $eco = Ecosystem.new(:ecosystem<fez>);
say $eco.meta-url;  # https://360.zef.pm/

=end code

The C<meta-url> instance method returns the URL that is used to
fetch the META data, if any.

=head2 most-recent-release

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.most-recent-release;

=end code

The C<most-recent-release> instance method returns the C<Date>
of the most recent release in the ecosystem, if any.

=head2 resolve

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.resolve("eigenstates");  # eigenstates:ver<0.0.9>:auth<zef:lizmat>

=end code

The C<resolve> instance method attempts to resolve the given string and the
given C<:ver>, C<:auth>, C<:api> and C<:from> named arguments to the
identity that would be assumed when specified with e.g. C<dependencies>.

=head2 reverse-dependencies

=begin code :lang<raku>

my $eco = Ecosystem.new;
my %reverse-dependencies := $eco.reverse-dependencies;
say "Found %reverse-dependencies.elems() reverse dependencies";

=end code

The C<reverse-dependencies> instance method returns a C<Map> keyed on
resolved dependencies, with a list of identities that depend on it.

=head2 reverse-dependencies-for-short-name

=begin code :lang<raku>

my $eco = Ecosystem.new;
.say for $eco.reverse-dependencies-for-short-name("File::Temp");

=end code

The C<reverse-dependencies-for-short-name> instance method returns
a unique list of short-names of identities that depend on any
version of the given short-name.

=head2 river

=begin code :lang<raku>

my $eco = Ecosystem.new;
say "Top five modules on the Raku Ecosystem River:";
.say for $eco.river.sort(-*.value.elems).map(*.key).head(5);

=end code

The C<river> instance method returns a C<Map> keyed on short-name of an
identity, with as value a list of short-names of identities that depend
on it B<without> having pinned C<:ver> and C<:auth> in their dependency
specification.

=head2 stale-period

=begin code :lang<raku>

my $eco = Ecosystem.new;
say $eco.stale-period;  # 86400

=end code

The C<stale-period> instance method returns the number of seconds
after which any locally stored META information is considered to
be stale.

=head2 update

=begin code :lang<raku>

my $eco = Ecosystem.new;
$eco.update;

=end code

The C<update> instance method re-fetches the META information from
the C<meta-url> and updates it internal state in a thread-safe
manner.

=head2 unresolvable-dependencies

=begin code :lang<raku>

my $eco = Ecosystem.new;
say "Found $eco.unresolvable-dependencies.elems() unresolvable dependencies";

=end code

The C<unresolvable-dependencies> instance method returns a C<Map>
keyed on an unresolved dependency, and a C<List> of identities
that have this unresolvable dependency as the value.  By default,
only current (as in the most recent version) identities will be
in the list.  You can specify the named C<:all> argument to have
also have the non-current identities listed.

=head2 unversioned-distros

=begin code :lang<raku>

my $eco = Ecosystem.new;
say "Found $eco.unversioned-distro-names.elems() unversioned distributions";

=end code

The C<unversioned-distro-names> instance method returns a sorted list of
distribution names (identity without C<:ver>) that do not have any
release with a valid C<:ver> value (typically B<:ver<*>>).

=head2 use-targets

=begin code :lang<raku>

my $eco = Ecosystem.new;
say "Found $eco.use-targets.elems() different 'use' targets";

=end code

The C<use-targets> instance method returns a C<Map> keyed on 'use'
target, with a sorted list of the identities that provide that
'use' target (sorted by short-name, latest version first).

=head1 AUTHOR

Elizabeth Mattijsen <liz@raku.rocks>

Source can be located at: https://github.com/lizmat/Ecosystem .
Comments and Pull Requests are welcome.

=head1 COPYRIGHT AND LICENSE

Copyright 2022 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
