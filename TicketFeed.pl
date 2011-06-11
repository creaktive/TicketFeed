#!/usr/bin/env perl
use common::sense;

=head1 TODO

 ticket.iwatcher.net. IN CNAME gateway.dotcloud.com.

=cut

use Business::CreditCard;
use Data::UUID;
use Mojolicious::Lite;
use Number::Format;
use XML::Atom::SimpleFeed;

my $json = new Mojo::JSON;
my $price = new Number::Format(
    '-int_curr_symbol'      => 'R$ ',
    '-mon_decimal_point'    => ',',
    '-mon_thousands_sep'    => '.',
);

any '/' => sub {
    my ($self) = @_;

    my $num = $self->param('num') // '';
    $num =~ s/\D//g;

    my $root = $self->req->url->clone;
    $root->query(new Mojo::Parameters);

    $self->stash(
        feed    => validate($num) ? $num : '',
        num     => $num,
        root    => $root->to_abs,
    );
    $self->render('index');
};

any '/feed/:num' => [num => qr/(\d{4}-?){4}/] => sub {
    my ($self) = @_;

    my $num = $self->param('num');
    $num =~ s/\D//g;
    return $self->redirect_to('/') unless validate($num);

    my $numstr = $num;
    $numstr =~ s/(\d{4}\B)/$1-/g;

    my $feed = new XML::Atom::SimpleFeed(
        title   => 'Saldo para ticket #' . $numstr,
        id      => 'urn:uuid:' . Data::UUID->new->create_from_name_str('ticket.iwatcher.net' => 'ticket' . $num),
    );

    local $_ = $self->ua->
        get('http://www.ticket.com.br/portal/portalcorporativo/dpages/service/consulteseusaldo/seeBalance.jsp?txtOperation=lancamentos&txtCardNumber=' . $num)->
        res->content->asset->slurp;

    s/\x27/"/g;
    s/(\w+):/"$1":/g;
    return $self->redirect_to('/error') unless /\bpreencherTelaLancamentos\((.+)\)/;

    my $result = [];
    eval { $result = $json->decode("[$1]"); };
    return $self->redirect_to('/error') if $@ or ref($result->[2]) ne 'ARRAY';

    for my $item (@{$result->[2]}) {
        $item->{$_} //= '' for qw(data valor descricao);
        if (my ($day, $month, $year) = ($item->{data} =~ m{(\d{1,2})/(\d{1,2})/(\d{4})})) {
            $item->{valor} =~ y/,././d;
            my $color   = ($item->{descricao} =~ /^DISPON\.\s+DE\s+BENEFICIO/i) ? '#080' : '#800';
            my $link    = 'http://www.ticket.com.br/portal/portalcorporativo/usuario/vazio/consulte-seu-saldo/consulte-seu-saldo.htm?cardNumber=' . $num;
            my $date    = sprintf('%04d-%02d-%02dT12:00:00Z', $year, $month, $day);
            $feed->add_entry(
                author      => $numstr,
                content     => "<span style='color: $color'>" . $price->format_price($item->{valor}, 2) . "</span> (" . $item->{data} . ")",
                id          => Data::UUID->new->create_from_name_str('ticket.com.br' => $num . $date),
                link        => $link,
                published   => $date,
                title       => $item->{descricao},
                updated     => $date,
            );
        }
    }

    $self->render(text => $feed->as_string, format => 'atom');
};

any '*' => sub {
    shift->redirect_to('/');
};

app->start;
