#!/usr/bin/perl -w
#
# msgconvert.pl:
#
# Convert .MSG files (made by Outlook (Express)) to multipart MIME messages.
#
# Copyright 2002, 2004 Matijs van Zuijlen
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
# Public License for more details.
#
# TODO (Functional)
# - Use address data to make To: and Cc: lines complete
# - Make use of more of the items, if possible.
#
# CHANGES:
# 20020715  Recognize new items 'Cc', mime type of attachment, long
#	    filename of attachment, and full headers. Attachments turn out
#	    to be numbered, so a regexp is now used to recognize label of
#	    items that are attachments.
# 20020831  long file name will definitely be used if present. Full headers
#	    and mime type information are used when present. Created
#	    generic system for specifying known items to be skipped.
#	    Unexpected contents is never reason to bail out anymore. Added
#	    support for usage message and option processing (--verbose).
# 20040104  Handle address data slightly better, make From line less fake,
#	    make $verbose and $skippable_entries global vars, handle HTML
#	    variant of body text if present (though not optimally).
# 20040214  Fix typos and incorrect comments.
# 20040307  - Complete rewrite: All functional parts are now in the package
#	      MSGParser;
#	    - Creation of MIME::Entity object is delayed until the output
#	      routines, which means all data is known; This means I can
#	      create a multipart/alternative body.
#	    - Item names are parsed, thanks to bfrederi@alumni.sfu.ca for
#	      the information
#
package MSGParser;
use strict;
use OLE::Storage_Lite;
use MIME::Entity;
use MIME::Parser;
use POSIX qw(mktime ctime);
use constant DIR_TYPE => 1;
use constant FILE_TYPE => 2;

#
# Descriptions partially based on mapitags.h
#
our $skipproperties = {
  # Envelope properties
  '001A' => "Type of message",
  '003B' => "Sender address variant",
  '003D' => "Contains 'Re: '",
  '0041' => "Sender variant address id",
  '0042' => "Sender variant name",
  '0046' => "Read receipt address id",
  '0053' => "Read receipt search key",
  '0064' => "Sender variant address type",
  '0065' => "Sender variant address",
  '0070' => "Conversation topic",
  '0071' => "Conversation index",
  # Recipient properties
  '0C19' => "Reply address variant",
  '0C1D' => "Reply address variant",
  '0C1E' => "Reply address type",
  # Non-transmittable properties
  '0E02' => "?Should BCC be displayed",
  '0E1D' => "Subject w/o Re",
  '0E27' => "64 bytes: Unknown",
  '0FF6' => "Index",
  '0FF9' => "Index",
  '0FFF' => "Address variant",
  # Content properties
  '1008' => "Summary or something",
  '1009' => "RTF Compressed",
  # 'Common property'
  '3001' => "Display name",
  '3002' => "Address Type",
  '300B' => "'Search key'",
  # 'Mail user'
  '3A20' => "Address variant",
  # 3900 -- 39FF: 'Address book'
  '39FF' => "7 bit display name",
  # 'Status object'
  '3FF8' => "Routing data",
  '3FF9' => "Routing data",
  '3FFA' => "Routing data",
  '3FFB' => "Routing data",
  # 'Transport-defined envelope property'
  '4029' => "Sender variant address type",
  '402A' => "Sender variant address",
  '402B' => "Sender variant name",
  # User defined id's
  '8000' => "Content Class",
};

our $skipheaders = {
  "MIME-Version" => 1,
  "Content-Type" => 1,
  "Content-Transfer-Encoding" => 1,
  "X-Mailer" => 1,
  "X-Msgconvert" => 1,
  "X-MS-Tnef-Correlator" => 1,
  "X-MS-Has-Attach" => 1,
};

#
# Main body of module
#

sub new {
  my $that = shift;
  my $class = ref $that || $that;

  my $self = {
    ATTACHMENTS => [],
    ADDRESSES => [],
    VERBOSE => 0
  };
  bless $self, $class;
}

#
# Main sub: parse the PPS tree, and return 
#
sub parse {
  my $self = shift;
  my $file = shift or die "Internal error: no file name";

  # Load and parse MSG file (is OLE)
  my $Msg = OLE::Storage_Lite->new($file);
  my $PPS = $Msg->getPpsTree(1);
  $PPS or die "$file must be an OLE file";

  $self->_RootDir($PPS);
}

sub print {
  my $self = shift;

  my $mime = MIME::Entity->build(Type => "multipart/mixed");
  my $bodymime;

  my $head = $self->{HEAD};
  foreach my $tag ($head->tags) {
    next if $skipheaders->{$tag};
    my @values = $head->get_all($tag);
    foreach my $value (@values) {
      $mime->head->add($tag, $value);
    }
  }

  # Set header fields
  $self->_AddHeaderField($mime, 'Date', $self->{OLEDATE});
  $self->_AddHeaderField($mime, 'Subject', $self->{SUBJECT});
  $self->_AddHeaderField($mime, 'From', $self->_Address("FROM"));
  #$self->_AddHeaderField($mime, 'Reply-To', $self->_Address("REPLYTO"));
  $self->_AddHeaderField($mime, 'To', $self->{TO});
  $self->_AddHeaderField($mime, 'Cc', $self->{CC});
  $self->_AddHeaderField($mime, 'Message-Id', $self->{MESSAGEID});

  # Set the entity that we'll save the body parts to. If there's more than
  # one part, it's a new entity, otherwise, it's the main $mime object.
  if ($self->{BODY_HTML} and $self->{BODY_PLAIN}) {
    $bodymime = MIME::Entity->build(
      Type => "multipart/alternative",
      Encoding => "8bit",
    );
    $mime->add_part($bodymime);
  } else {
    $bodymime = $mime;
  }
  if ($self->{BODY_PLAIN}) {
    $self->_SaveAttachment($bodymime, {
      MIMETYPE => 'text/plain; charset=ISO-8859-1',
      ENCODING => '8bit',
      DATA => $self->{BODY_PLAIN},
      DISPOSITION => 'inline',
    });
  }
  if ($self->{BODY_HTML}) {
    $self->_SaveAttachment($bodymime, {
      MIMETYPE => 'text/html',
      ENCODING => '8bit',
      DATA => $self->{BODY_HTML},
      DISPOSITION => 'inline',
    });
  }
  foreach my $att (@{$self->{ATTACHMENTS}}) {
    $self->_SaveAttachment($mime, $att);
  }
  foreach my $address (@{$self->{ADDRESSES}}) {
    warn "Address ($address->{TYPE}): $address->{NAME} <$address->{ADDRESS}>\n";
  }

  # Construct From line from whatever we know.
  my $string = "";
  $string = (
    $self->{FROM_ADDR_TYPE} eq "SMTP" ?
    $self->{FROM_ADDR} :
    'someone@somewhere'
  );
  $string =~ s/\n//g;
  print "From ", $string, " ", $self->{OLEDATE};
  $mime->print(\*STDOUT);
  print "\n";
}

sub set_verbosity {
  my $self = shift;
  my $verbosity = shift or die "Internal error: no verbosity level";
  $self->{VERBOSE} = $verbosity;
}

#
# Below are functions that walk the PPS tree. The *Dir functions handle
# processing the directory nodes of the tree (mainly, iterating over the
# children), whereas the *Item functions handle processing the items in the
# directory (if such an item is itself a directory, it will in turn be
# processed by the relevant *Dir function).
#

#
# RootItem: Check Root Entry, parse sub-entries.
# The OLE file consists of a single entry called Root Entry, which has
# several children. These children are parsed in the sub SubItem.
# 
sub _RootDir {
  my $self = shift;
  my $PPS = shift;

  my $name = $self->_GetName($PPS);

  $name eq "Root Entry" or warn "Unexpected root entry name $name";

  foreach my $child (@{$PPS->{Child}}) {
    $self->_SubItem($child);
  }
}

sub _SubItem {
  my $self = shift;
  my $PPS = shift;
  
  my $name = $self->_GetName($PPS);
  # DIR Entries:
  if ($PPS->{Type} == DIR_TYPE) {
    $self->_GetOLEDate($PPS);
    if ($name =~ /__recip_version1 0_ /) { # Address of one recipient
      $self->_AddressDir($PPS);
    } elsif ($name =~ '__attach_version1 0_ ') { # Attachment
      $self->_AttachmentDir($PPS);
    } else {
      $self->_UnknownDir($name);
    }
  } elsif ($PPS->{Type} == FILE_TYPE) {
    my ($property, $encoding) = $self->_ParseItemName($name);
    if (defined $property) {
      # Next two bits are saved as a ref to the data
      if ($property eq '1000') {	# Body
	$self->{BODY_PLAIN} = \($PPS->{Data});
      } elsif ($property eq '1013') {	# HTML Version of body
	$self->{BODY_HTML} = \($PPS->{Data});
      } else {
	# Other bits are small enough to always store directly.
	my $data = $PPS->{Data};
	$data =~ s/\000//g;
	if ($property eq '0037') {	# Subject
	  $self->{SUBJECT} = $data;
	} elsif ($property eq '007D') {	# Full headers
	  $self->{HEAD} = $self->_ParseHead($data);
	} elsif ($property eq '0C1A') {	# Reply-To: Name
	  $self->{FROM} = $data;
	} elsif ($property eq '0C1E') {	# From: Address type
	  $self->{FROM_ADDR_TYPE} = $data;
	} elsif ($property eq '0C1F') {	# Reply-To: Address
	  $self->{FROM_ADDR} = $data;
	} elsif ($property eq '0E04') {	# To: Names
	  $self->{TO} = $data;
	} elsif ($property eq '0E03') {	# Cc: Names
	  $self->{CC} = $data;
	} elsif ($property eq '1035') {	# Message-Id
	  $self->{MESSAGEID} = $data;
	} else {
	  $self->_UnknownFile($name);
	}
      }
    } else {
      $self->_UnknownFile($name);
    }
  } else {
    warn "Unknown entry type: $PPS->{Type}";
  }
}

sub _AddressDir {
  my $self = shift;
  my $PPS = shift;

  my $address = {
    NAME	=> undef,
    ADDRESS	=> undef,
  };
  foreach my $child (@{$PPS->{Child}}) {
    $self->_AddressItem($child, $address);
  }
  push @{$self->{ADDRESSES}}, $address;
}

sub _AddressItem {
  my $self = shift;
  my $PPS = shift;
  my $addr_info = shift;

  my $name = $self->_GetName($PPS);

  # DIR Entries: There should be none.
  if ($PPS->{Type} == DIR_TYPE) {
    $self->_UnknownDir($name);
  } elsif ($PPS->{Type} == FILE_TYPE) {
    my ($property, $encoding) = $self->_ParseItemName($name);
    if (defined $property) {
      my $data = $PPS->{Data};
      $data =~ s/\000//g;
      if ($property eq '3001') {	# Real Name
	$addr_info->{NAME} = $data;
      } elsif ($property eq '403D') {	# Address type
	$addr_info->{TYPE} = $data;
      } elsif (
	$property eq '3003' or
	$property eq '403E'
      ) {	# Address
	if ($data =~ /@/) {
	  if (defined ($addr_info->{ADDRESS})) {
	    warn "More than one address";
	  }
	  $addr_info->{ADDRESS} = $data;
	}
      } else {
	$self->_UnknownFile($name);
      }
    } else {
      $self->_UnknownFile($name);
    }
  }
  else {
    warn "Unknown entry type: $PPS->{Type}";
  }
}

sub _AttachmentDir {
  my $self = shift;
  my $PPS = shift;

  my $attachment = {
    SHORTNAME	=> undef,
    LONGNAME	=> undef,
    MIMETYPE	=> 'application/octet-stream',
    ENCODING	=> 'base64',
    DISPOSITION	=> 'attachment',
    DATA	=> undef
  };
  foreach my $child (@{$PPS->{Child}}) {
    $self->_AttachmentItem($child, $attachment);
  }
  push @{$self->{ATTACHMENTS}}, $attachment;
}

sub _AttachmentItem {
  my $self = shift;
  my $PPS = shift;
  my $att_info = shift;

  my $name = $self->_GetName($PPS);

  if ($PPS->{Type} == DIR_TYPE) {
    $self->_UnknownDir($name);
  } elsif ($PPS->{Type} == FILE_TYPE) {
    my ($property, $encoding) = $self->_ParseItemName($name);
    if (defined $property) {
      if ($property eq '3701') {	# File contents
	# store a reference to it.
	$att_info->{DATA} = \($PPS->{Data});
      } else {
	my $data = $PPS->{Data};
	$data =~ s/\000//g;
	if ($property eq '3704') {	# Short file name
	  $att_info->{SHORTNAME} = $data;
	} elsif ($property eq '3707') {	# Long file name
	  $att_info->{LONGNAME} = $data;
	} elsif ($property eq '370E') {	# mime type
	  $att_info->{MIMETYPE} = $data;
	} elsif ($property eq '3716') {	# disposition
	  $att_info->{DISPOSITION} = $data;
	} else {
	  $self->_UnknownFile($name);
	}
      }
    } else {
      $self->_UnknownFile($name);
    }
  } else {
    warn "Unknown entry type: $PPS->{Type}";
  }
}

sub _UnknownDir {
  my $self = shift;
  my $name = shift;
  if ($name eq '__nameid_version1 0') {
    $self->{VERBOSE}
      and warn "Skipping DIR entry $name (Introductory stuff)\n";
    return;
  }
  warn "Unknown DIR entry $name\n";
}

sub _UnknownFile {
  my $self = shift;
  my $name = shift;

  if ($name eq '__properties_version1 0') {
    $self->{VERBOSE}
      and warn "Skipping FILE entry $name (Properties)\n";
    return;
  }

  my ($property, $encoding) = $self->_ParseItemName($name);
  if (defined $property) {
    if ($skipproperties->{$property}) {
      $self->{VERBOSE}
	and warn "Skipping property $property ($skipproperties->{$property})\n";
      return;
    } else {
      warn "Unknown property $property\n";
      return;
    }
  }
  warn "Unknown FILE entry $name\n";
}

#
# Helper functions
#

sub _GetName {
  my $self = shift;
  my $PPS = shift;

  return $self->_NormalizeWhiteSpace(OLE::Storage_Lite::Ucs2Asc($PPS->{Name}));
}

sub _NormalizeWhiteSpace {
  my $self = shift;
  my $name = shift;
  $name =~ s/\W/ /g;
  return $name;
}

sub _GetOLEDate {
  my $self = shift;
  my $PPS = shift;
  unless (defined ($self->{OLEDATE})) {
    # Make Date
    my $date;
    $date = $PPS->{Time2nd};
    $date = $PPS->{Time1st} unless($date);
    if ($date) {
      my $time = mktime(@$date);
      my $datestring = sprintf(
	"%02d.%02d.%4d %02d:%02d:%02d",
	$date->[3], $date->[4]+1, $date->[5]+1900,
	$date->[2], $date->[1],   $date->[0]
      );
      $self->{OLEDATE} = ctime($time);
    }
  }
}

sub _ParseItemName {
  my $self = shift;
  my $name = shift;

  if ($name =~ /^__substg1 0_(....)(....)$/) {
    my ($property, $encoding) = ($1, $2);
    if ($encoding eq '001F') {
      warn "File contains Unicode fields. This is untested.\n";
    }
    return ($property, $encoding);
  } else {
    return (undef, undef);
  }
}

sub _SaveAttachment {
  my $self = shift;
  my $mime = shift;
  my $att = shift;

  my $handle;
  my $ent = $mime->attach(
    Type => $att->{MIMETYPE},
    Encoding => $att->{ENCODING},
    Data => [],
    Filename => ($att->{LONGNAME} ? $att->{LONGNAME} : $att->{SHORTNAME}),
    Disposition => $att->{DISPOSITION}
  );
  if ($handle = $ent->open("w")) {
    $handle->print(${$att->{DATA}});
    $handle->close;
  } else {
    warn "Could not write data!";
  }
}

sub _SetAddressPart {
  my $self = shift;
  my $adrname = shift;
  my $partname = shift;
  my $data = shift;

  my $address = $self->{ADDRESSES}->{$adrname};
  $data =~ s/\000//g;
  #warn "Processing address data part $partname : $data\n";
  if (defined ($address->{$partname})) {
    if ($address->{$partname} eq $data) {
      warn "Skipping duplicate but identical address information for"
      . " $partname\n" if $self->{VERBOSE};
    } else {
      warn "Address information $partname inconsistent:\n";
      warn "    Original data: $address->{$partname}\n";
      warn "    New data: $data\n";
    }
  } else {
    $address->{$partname} = $data;
  }
}

# Set header fields
sub _AddHeaderField {
  my $self = shift;
  my $mime = shift;
  my $fieldname = shift;
  my $value = shift;

  my $oldvalue = $mime->head->get($fieldname);
  return if $oldvalue;
  $mime->head->add($fieldname, $value) if $value;
}

sub _Address {
  my $self = shift;
  my $tag = shift;
  my $name = $self->{$tag};
  my $address = $self->{$tag . "_ADDR"};
  my $type = $self->{$tag . "_ADDR_TYPE"};
  return "\"$name\"" . ($type eq "SMTP" ? " <$address>" : "");
}

sub _ParseHead {
  my $self = shift;
  my $data = shift;
  # Parse full header date if we got that.
  my $parser = new MIME::Parser();
  $parser->output_to_core(1);
  $parser->decode_headers(1);
  $data =~ s/^Microsoft Mail.*$/X-MSGConvert: yes/m;
  my $entity = $parser->parse_data($data)
    or warn "Couldn't parse full headers!"; 
  my $head = $entity->head;
  $head->unfold;
  return $head;
}

package main;
use Getopt::Long;
use Pod::Usage;

# Setup command line processing.
my $verbose = '';
my $help = '';	    # Print help message and exit.
GetOptions('verbose' => \$verbose, 'help|?' => \$help) or pod2usage(2);
pod2usage(1) if $help;

# Get file name
my $file = $ARGV[0];
defined $file or pod2usage(2);
warn "Will parse file: $file\n" if $verbose; 

# parse file
my $parser = new MSGParser();
$parser->set_verbosity(1) if $verbose;
$parser->parse($file);
$parser->print();

#
# Usage info follows.
#
__END__

=head1 NAME

msgconvert.pl - Convert Outlook .msg files to mbox format

=head1 SYNOPSIS

msgconvert.pl [options] <file.msg>

  Options:
    --verbose	be verbose
    --help	help message

=head1 OPTIONS

=over 8

=item B<--verbose>

    Print information about skipped parts of the .msg file.

=item B<--help>

    Print a brief help message.

=head1 DESCRIPTION

This program will output the message contained in file.msg in mbox format
on stdout. It will complain about unrecognized OLE parts on
stderr.

=head1 BUGS

Not all data that's in the .MSG file is converted. There simply are some
parts whose meaning escapes me. One of these must contain the date the
message was sent, for example. Formatting of text messages will also be
lost. YMMV.

=cut