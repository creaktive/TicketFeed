#!/usr/bin/env perl
#
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    PREREQ_PM => {
        'common::sense'         => 0,
        'Business::CreditCard'  => 0,
        'DateTime'              => 0,
        'Mojolicious'           => 0,
        'Number::Format'        => 0,
        'XML::Feed'             => 0,
    },
);
