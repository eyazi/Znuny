# --
# Copyright (C) 2001-2018 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::Output::HTML::NotificationCustomerOnline;

use strict;
use warnings;

use Kernel::System::AuthSession;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # get needed objects
    for (qw(ConfigObject LogObject DBObject LayoutObject TimeObject UserID)) {
        $Self->{$_} = $Param{$_} || die "Got no $_!";
    }
    $Self->{SessionObject} = Kernel::System::AuthSession->new(%Param);
    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $SessionMaxIdleTime = $Self->{ConfigObject}->Get('SessionMaxIdleTime');

    # get session info
    my %Online   = ();
    my @Sessions = $Self->{SessionObject}->GetAllSessionIDs();
    for (@Sessions) {
        my %Data = $Self->{SessionObject}->GetSessionIDData(
            SessionID => $_,
        );
        if (
            $Data{UserType} eq 'Customer'
            && $Data{UserLastRequest}
            && $Data{UserLastRequest} + $SessionMaxIdleTime > $Self->{TimeObject}->SystemTime()
            && $Data{UserFirstname}
            && $Data{UserLastname}
            )
        {
            $Online{ $Data{UserID} } = "$Data{UserFirstname} $Data{UserLastname}";
            if ( $Param{Config}->{ShowEmail} ) {
                $Online{ $Data{UserID} } .= " ($Data{UserEmail})";
            }
        }
    }
    for ( sort { $Online{$a} cmp $Online{$b} } keys %Online ) {
        if ( $Param{Message} ) {
            $Param{Message} .= ', ';
        }
        $Param{Message} .= "$Online{$_}";
    }
    if ( $Param{Message} ) {
        return $Self->{LayoutObject}->Notify(
            Info => $Self->{LayoutObject}->{LanguageObject}->Translate(
                'Online Customer: %s',
                $Param{Message},
            ),
        );
    }
    else {
        return '';
    }
}

1;