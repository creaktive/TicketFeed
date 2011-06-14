#!/usr/bin/env perl
use common::sense;
use strict;

=head1 TODO

 ticket.iwatcher.net. IN CNAME gateway.dotcloud.com.

=cut

use Business::CreditCard;
use DateTime;
use Mojolicious::Lite;
use Number::Format;
use XML::Feed;

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

any '/balance/:num' => [num => qr/(\d{4}-?){4}/] => sub {
    my ($self) = @_;

    my $num = $self->param('num');
    $num =~ s/\D//g;
    return $self->redirect_to('/') unless validate($num);

    local $_ = $self->ua->
        get('http://www.ticket.com.br/portal/portalcorporativo/dpages/service/consulteseusaldo/seeBalance.jsp?txtOperacao=saldo_agendamentos&txtNumeroCartao=' . $num)->
        res->content->asset->slurp;

    my $balance = '';
    my $date    = '';
    if (m{\bpreencherPainelSaldos\('(\d{1,2}/\d{1,2}/\d{4})'\s*,\s*'([\d\,\.]+)'}) {
        $date = $1;
        $balance = $2;
        $balance =~ y/,././d;
    }

    $self->stash(
        balance     => $price->format_price($balance, 2),
        date        => $date,
    );
    $self->render('balance', format => 'svg');
};

any '/feed/:num' => [num => qr/(\d{4}-?){4}/] => sub {
    my ($self) = @_;

    my $num = $self->param('num');
    $num =~ s/\D//g;
    return $self->redirect_to('/') unless validate($num);

    my $numstr = $num;
    $numstr =~ s/(\d{4}\B)/$1-/g;

    my $root = $self->req->url->clone;
    $root->path('/');

    my $feed = new XML::Feed('RSS', version => '2.0');
    $feed->description('Alimentando o seu leitor de feeds');
    $feed->link($root->to_abs);
    $feed->modified(DateTime->now);
    $feed->self_link($self->req->url->to_abs);
    $feed->title('TicketFeed');

    local $_ = $self->ua->
        get('http://www.ticket.com.br/portal/portalcorporativo/dpages/service/consulteseusaldo/seeBalance.jsp?txtOperation=lancamentos&txtCardNumber=' . $num)->
        res->content->asset->slurp;

    s/\x27/"/g;
    s/(\w+):/"$1":/g;
    return $self->redirect_to('/error') unless /\bpreencherTelaLancamentos\((.+)\)/;

    my $result = [];
    eval { $result = $json->decode("[$1]"); };
    return $self->redirect_to('/error') if $@ or ref($result->[2]) ne 'ARRAY';

    my $balance_url = $self->req->url->to_abs;
    $balance_url =~ s{/feed/}{/balance/};

    my $i = 0;
    for my $item (@{$result->[2]}) {
        $item->{$_} //= '' for qw(data valor descricao);
        if (my ($day, $month, $year) = ($item->{data} =~ m{(\d{1,2})/(\d{1,2})/(\d{4})})) {
            $item->{valor} =~ y/,././d;
            my $color   = ($item->{descricao} =~ /^DISPON\.\s+DE\s+BENEFICIO/i) ? '#080' : '#800';
            my $link    = 'http://www.ticket.com.br/portal/portalcorporativo/usuario/vazio/consulte-seu-saldo/consulte-seu-saldo.htm?cardNumber=' . $num;

            my $date = new DateTime(
                year        => $year,
                month       => $month,
                day         => $day,
                hour        => 12,
                minute      => 00,
                second      => 00,
                time_zone   => 'America/Sao_Paulo',
            );
            my $id = $date->epoch + $i;

            my $content = "<span style='color: $color'>";
            $content    .= $price->format_price($item->{valor}, 2);
            $content    .= "</span> (" . $item->{data} . ")<br/>";
            $content    .= qq{<iframe id="balance" name="balance" src="$balance_url?id=$id" width="300" height="20" frameborder="0" marginheight="0" marginwidth="0" scrolling="no" allowtransparency="true"></iframe>};

            my $entry = new XML::Feed::Entry;
            $entry->author('noreply@' . $root->to_abs->host . " (TicketFeed #$numstr)");
            $entry->content($content);
            $entry->link($link . '#' . $id);
            $entry->modified($date);
            $entry->summary($content);
            $entry->title($item->{descricao});
            $feed->add_entry($entry);
        }
    } continue {
        ++$i;
    }

    $self->render(text => $feed->as_xml, format => 'rss');
};

any '*' => sub {
    shift->redirect_to('/');
};

app->secret($0);
app->start;
