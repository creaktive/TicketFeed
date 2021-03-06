#!/usr/bin/env perl
use common::sense;
use strict;

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

any '/balance/:num/:id' => [num => qr/(\d{4}-?){4}/, id => qr/\d+/] => sub {
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

any '/redir/:num/:id' => [num => qr/(\d{4}-?){4}/, id => qr/\d+/] => sub {
    my ($self) = @_;
    return $self->redirect_to('http://www.ticket.com.br/portal/portalcorporativo/usuario/vazio/consulte-seu-saldo/consulte-seu-saldo.htm?cardNumber=' . $self->param('num'));
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

    my %count;
    my $last_modified = 0;
    for my $item (@{$result->[2]}) {
        $item->{$_} //= '' for qw(data valor descricao);
        if (my ($day, $month, $year) = ($item->{data} =~ m{(\d{1,2})/(\d{1,2})/(\d{4})})) {
            $item->{valor} =~ y/,././d;
            my $color   = ($item->{descricao} =~ /^DISPON\.\s+DE\s+BENEFICIO/i) ? '#080' : '#800';

            my $date = new DateTime(
                year        => $year,
                month       => $month,
                day         => $day,
                hour        => 12,
                minute      => 00,
                second      => 00,
                time_zone   => 'America/Sao_Paulo',
            );
            $date->subtract(minutes => $count{$date->epoch}++);
            my $id = $date->epoch;
            $last_modified = $id if $last_modified < $id;

            my $content = "<span style='color: $color'>";
            $content    .= $price->format_price($item->{valor}, 2);
            $content    .= "</span> (" . $item->{data} . ")<br/>";
            $content    .= qq{<img src="$balance_url/$id" width="300" height="20" border="0" alt="" title=""/>};

            my $entry = new XML::Feed::Entry;

            $entry->author('noreply@' . $root->to_abs->host . " (TicketFeed #$numstr)");
            $entry->content($content);
            $entry->id($id);
            $entry->issued($date);
            $entry->link($root->to_abs . 'redir/' . $num . '/' . $id);
            $entry->modified($date);
            $entry->summary($content);
            $entry->title($item->{descricao});

            $feed->add_entry($entry);
        }
    }

    $feed->modified(DateTime->from_epoch(epoch => $last_modified));
    $self->render(text => $feed->as_xml, format => 'rss');
};

any '*' => sub {
    shift->redirect_to('/');
};

app->secret($0);
app->start;
