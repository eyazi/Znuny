# --
# Kernel/Modules/AgentForward.pm - to forward a message
# Copyright (C) 2001-2005 Martin Edenhofer <martin+code@otrs.org>
# --
# $Id: AgentForward.pm,v 1.46 2005-02-10 20:17:59 martin Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

package Kernel::Modules::AgentForward;

use strict;
use Kernel::System::CheckItem;
use Kernel::System::StdAttachment;
use Kernel::System::State;
use Kernel::System::SystemAddress;
use Kernel::System::CustomerUser;
use Kernel::System::Web::UploadCache;
use Mail::Address;

use vars qw($VERSION);
$VERSION = '$Revision: 1.46 $';
$VERSION =~ s/^\$.*:\W(.*)\W.+?$/$1/;

# --
sub new {
    my $Type = shift;
    my %Param = @_;

    # allocate new hash for object
    my $Self = {};
    bless ($Self, $Type);

    $Self->{Debug} = $Param{Debug} || 0;

    # get common opjects
    foreach (keys %Param) {
        $Self->{$_} = $Param{$_};
    }

    # check all needed objects
    foreach (qw(TicketObject ParamObject DBObject QueueObject LayoutObject
      ConfigObject LogObject)) {
        die "Got no $_" if (!$Self->{$_});
    }
    # some new objects
    $Self->{CustomerUserObject} = Kernel::System::CustomerUser->new(%Param);
    $Self->{CheckItemObject} = Kernel::System::CheckItem->new(%Param);
    $Self->{StdAttachmentObject} = Kernel::System::StdAttachment->new(%Param);
    $Self->{StateObject} = Kernel::System::State->new(%Param);
    $Self->{SystemAddress} = Kernel::System::SystemAddress->new(%Param);
    $Self->{UploadCachObject} = Kernel::System::Web::UploadCache->new(%Param);
    # get params
    foreach (qw(From To Cc Bcc Subject Body InReplyTo ComposeStateID ArticleTypeID
      ArticleID TimeUnits Year Month Day Hour Minute AttachmentUpload
      AttachmentDelete1 AttachmentDelete2 AttachmentDelete3 AttachmentDelete4
      AttachmentDelete5 AttachmentDelete6 AttachmentDelete7 AttachmentDelete8
      AttachmentDelete9 AttachmentDelete10 FormID)) {
        my $Value = $Self->{ParamObject}->GetParam(Param => $_);
#        $Self->{GetParam}->{$_} = defined $Value ? $Value : '';
       if (defined($Value)) {
           $Self->{GetParam}->{$_} = $Value;
       }
    }
    # create form id
    if (!$Self->{GetParam}->{FormID}) {
        $Self->{GetParam}->{FormID} = $Self->{UploadCachObject}->FormIDCreate();
    }

    return $Self;
}
# --
sub Run {
    my $Self = shift;
    my %Param = @_;
    my $Output;

    if ($Self->{Subaction} eq 'SendEmail') {
        $Output = $Self->SendEmail();
    }
    else {
        $Output = $Self->Form();
    }
    return $Output;
}
# --
sub Form {
    my $Self = shift;
    my %Param = @_;
    my $Output;
    my %Error = ();
    my %GetParam = %{$Self->{GetParam}};
    # start with page ...
    $Output .= $Self->{LayoutObject}->Header(Area => 'Agent', Title => 'Forward');
    # check needed stuff
    if (!$Self->{TicketID}) {
        return $Self->{LayoutObject}->ErrorScreen(
                Message => "Got no TicketID!",
                Comment => 'System Error!',
        );
    }
    # get ticket data
    my %Ticket = $Self->{TicketObject}->TicketGet(TicketID => $Self->{TicketID});
    # check permissions
    if (!$Self->{TicketObject}->Permission(
        Type => 'forward',
        TicketID => $Self->{TicketID},
        UserID => $Self->{UserID})) {
        # error screen, don't show ticket
        return $Self->{LayoutObject}->NoPermission(WithHeader => 'yes');
    }
    # get lock state && write (lock) permissions
    if (!$Self->{TicketObject}->LockIsTicketLocked(TicketID => $Self->{TicketID})) {
        # set owner
        $Self->{TicketObject}->OwnerSet(
            TicketID => $Self->{TicketID},
            UserID => $Self->{UserID},
            NewUserID => $Self->{UserID},
        );
        # set lock
        if ($Self->{TicketObject}->LockSet(
            TicketID => $Self->{TicketID},
            Lock => 'lock',
            UserID => $Self->{UserID}
        )) {
            # show lock state
            $Output .= $Self->{LayoutObject}->TicketLocked(TicketID => $Self->{TicketID});
        }
    }
    else {
        my ($OwnerID, $OwnerLogin) = $Self->{TicketObject}->OwnerCheck(
            TicketID => $Self->{TicketID},
        );
        if ($OwnerID != $Self->{UserID}) {
            $Output .= $Self->{LayoutObject}->Warning(
                Message => "Sorry, the current owner is $OwnerLogin!",
                Comment => 'Please change the owner first.',
            );
            $Output .= $Self->{LayoutObject}->Footer();
            return $Output;
        }
    }
    # get last customer article or selecte article ...
    my %Data = ();
    if ($GetParam{ArticleID}) {
        %Data = $Self->{TicketObject}->ArticleGet(
            ArticleID => $GetParam{ArticleID},
        );
    }
    else {
        %Data = $Self->{TicketObject}->ArticleLastCustomerArticle(
            TicketID => $Self->{TicketID},
        );
    }
    # add attachmens to upload cache
    my %AttachmentIndex = $Self->{TicketObject}->ArticleAttachmentIndex(
        %Data,
    );
    foreach (keys %AttachmentIndex) {
        my %Attachment = $Self->{TicketObject}->ArticleAttachment(
            ArticleID => $Data{ArticleID},
            FileID => $_,
        );
        $Self->{UploadCachObject}->FormIDAddFile(
            FormID => $GetParam{FormID},
            %Attachment,
        );
    }
    # get all attachments meta data
    my @Attachments = $Self->{UploadCachObject}->FormIDGetAllFilesMeta(
        FormID => $GetParam{FormID},
    );

    # --
    # get customer data
    # --
    my %Customer = ();
    if ($Ticket{CustomerUserID}) {
        %Customer = $Self->{CustomerUserObject}->CustomerUserDataGet(
            User => $Ticket{CustomerUserID},
        );
    }
    # --
    # prepare salutation
    # --
    $Data{Salutation} = $Self->{QueueObject}->GetSalutation(%Ticket);
    # prepare signature
    $Data{Signature} = $Self->{QueueObject}->GetSignature(%Ticket);
    foreach (qw(Signature Salutation)) {
        # get and prepare realname
        if ($Data{$_} =~ /<OTRS_CUSTOMER_REALNAME>/) {
            my $From = '';
            if ($Ticket{CustomerUserID}) {
                $From = $Self->{CustomerUserObject}->CustomerName(UserLogin => $Ticket{CustomerUserID});
            }
            if (!$From) {
                $From = $Data{OrigFrom} || '';
                $From =~ s/<.*>|\(.*\)|\"|;|,//g;
                $From =~ s/( $)|(  $)//g;
            }
            $Data{$_} =~ s/<OTRS_CUSTOMER_REALNAME>/$From/g;
        }
        # replace other needed stuff
        $Data{$_} =~ s/<OTRS_FIRST_NAME>/$Self->{UserFirstname}/g;
        $Data{$_} =~ s/<OTRS_LAST_NAME>/$Self->{UserLastname}/g;
        $Data{$_} =~ s/<OTRS_USER_ID>/$Self->{UserID}/g;
        $Data{$_} =~ s/<OTRS_USER_LOGIN>/$Self->{UserLogin}/g;
        # replace ticket data
        foreach my $TicketKey (keys %Ticket) {
            if ($Ticket{$TicketKey}) {
                $Data{$_} =~ s/<OTRS_TICKET_$TicketKey>/$Ticket{$TicketKey}/gi;
            }
        }
        # cleanup all not needed <OTRS_TICKET_ tags
        $Data{$_} =~ s/<OTRS_TICKET_.+?>/-/gi;
        # replace customer data
        foreach my $CustomerKey (keys %Customer) {
            if ($Customer{$CustomerKey}) {
                $Data{$_} =~ s/<OTRS_CUSTOMER_$CustomerKey>/$Customer{$CustomerKey}/gi;
            }
        }
        # cleanup all not needed <OTRS_CUSTOMER_ tags
        $Data{$_} =~ s/<OTRS_CUSTOMER_.+?>/-/gi;
        # replace config options
        $Data{$_} =~ s{<OTRS_CONFIG_(.+?)>}{$Self->{ConfigObject}->Get($1)}egx;
    }
    # --
    # check if original content isn't text/plain or text/html, don't use it
    # --
    if ($Data{'ContentType'}) {
        if($Data{'ContentType'} =~ /text\/html/i) {
            $Data{Body} =~ s/\<.+?\>//gs;
        }
        elsif ($Data{'ContentType'} !~ /text\/plain/i) {
            $Data{Body} = "-> no quotable message <-";
        }
    }
    # --
    # prepare body, subject, ReplyTo ...
    # --
    $Data{Body} =~ s/(^>.+|.{4,78})(?:\s|\z)/$1\n/gm;
    $Data{Body} =~ s/\n/\n> /g;
    $Data{Body} = "\n> " . $Data{Body};
    foreach (qw(Subject ReplyTo Cc To From)) {
        if ($Data{$_}) {
            $Data{Body} = "$_: $Data{$_}\n".$Data{Body};
        }
    }
    $Data{Body} = "---- Forwarded message from $Data{From} ---\n\n".$Data{Body};
    $Data{Body} .= "\n---- End forwarded message ---\n";
    $Data{Body} = $Data{Signature}.$Data{Body};
    $Data{Subject} = $Self->{TicketObject}->TicketSubjectBuild(
        TicketNumber => $Ticket{TicketNumber},
        Subject => $Data{Subject} || '',
    );
    my %Address = $Self->{QueueObject}->GetSystemAddress(%Ticket);
    $Data{From} = "$Address{RealName} <$Address{Email}>";
    $Data{Email} = $Address{Email};
    $Data{RealName} = $Address{RealName};

    # --
    # check some values
    # --
    foreach (qw(To Cc Bcc)) {
        if ($Data{$_}) {
            delete $Data{$_};
        }
    }
    # run compose modules
    if (ref($Self->{ConfigObject}->Get('Frontend::ArticleComposeModule')) eq 'HASH') {
        my %Jobs = %{$Self->{ConfigObject}->Get('Frontend::ArticleComposeModule')};
        foreach my $Job (sort keys %Jobs) {
                # log try of load module
                if ($Self->{Debug} > 1) {
                    $Self->{LogObject}->Log(
                        Priority => 'debug',
                        Message => "Try to load module: $Jobs{$Job}->{Module}!",
                    );
                }
                if (eval "require $Jobs{$Job}->{Module}") {
                    my $Object = $Jobs{$Job}->{Module}->new(
                        %{$Self},
                        Debug => $Self->{Debug},
                    );
                    # log loaded module
                    if ($Self->{Debug} > 1) {
                        $Self->{LogObject}->Log(
                            Priority => 'debug',
                            Message => "Module: $Jobs{$Job}->{Module} loaded!",
                        );
                    }
                    # get params
                    foreach ($Object->Option(%Data, %GetParam, Config => $Jobs{$Job})) {
                        $GetParam{$_} = $Self->{ParamObject}->GetParam(Param => $_);
                    }
                    # run module
                    $Object->Run(%Data, %GetParam, Config => $Jobs{$Job});
                    # get errors
                    %Error = (%Error, $Object->Error(%GetParam, Config => $Jobs{$Job}));
                }
                else {
                    $Self->{LogObject}->Log(
                        Priority => 'error',
                        Message => "Can't load module $Jobs{$Job}->{Module}!",
                    );
                }
        }
    }
    # get free text config options
    my %TicketFreeText = ();
    foreach (1..8) {
        $TicketFreeText{"TicketFreeKey$_"} = $Self->{TicketObject}->TicketFreeTextGet(
            TicketID => $Self->{TicketID},
            Type => "TicketFreeKey$_",
            Action => $Self->{Action},
            UserID => $Self->{UserID},
        );
        $TicketFreeText{"TicketFreeText$_"} = $Self->{TicketObject}->TicketFreeTextGet(
            TicketID => $Self->{TicketID},
            Type => "TicketFreeText$_",
            Action => $Self->{Action},
            UserID => $Self->{UserID},
        );
    }
    my %TicketFreeTextHTML = $Self->{LayoutObject}->AgentFreeText(
        Ticket => \%Ticket,
        Config => \%TicketFreeText,
    );
    # build view ...
    $Output .= $Self->_Mask(
        TicketNumber => $Ticket{TicketNumber},
        TicketID => $Self->{TicketID},
        QueueID => $Ticket{QueueID},
        NextStates => $Self->_GetNextStates(),
        Errors => \%Error,
        Attachments => \@Attachments,
        %Data,
        %GetParam,
        %TicketFreeTextHTML,
    );
    $Output .= $Self->{LayoutObject}->Footer();

    return $Output;
}
# --
sub SendEmail {
    my $Self = shift;
    my %Param = @_;
    my %Error = ();
    my %GetParam = %{$Self->{GetParam}};
    my $Output = '';
    my $QueueID = $Self->{QueueID};
    my %StateData = $Self->{TicketObject}->{StateObject}->StateGet(
        ID => $GetParam{ComposeStateID},
    );
    my $NextState = $StateData{Name};

    # check pending date
    if ($StateData{TypeName} && $StateData{TypeName} =~ /^pending/i) {
        if (!$Self->{TimeObject}->Date2SystemTime(%GetParam, Second => 0)) {
            $Error{"Date invalid"} = 'invalid';
        }
    }
    # attachment delete
    foreach (1..10) {
        if ($GetParam{"AttachmentDelete$_"}) {
            $Error{AttachmentDelete} = 1;
            $Self->{UploadCachObject}->FormIDRemoveFile(
                FormID => $GetParam{FormID},
                FileID => $_,
            );
        }
    }
    # attachment upload
    if ($GetParam{AttachmentUpload}) {
        $Error{AttachmentUpload} = 1;
        my %UploadStuff = $Self->{ParamObject}->GetUploadAll(
            Param => "file_upload",
            Source => 'string',
        );
        $Self->{UploadCachObject}->FormIDAddFile(
            FormID => $GetParam{FormID},
            %UploadStuff,
        );
    }
    # get all attachments meta data
    my @Attachments = $Self->{UploadCachObject}->FormIDGetAllFilesMeta(
        FormID => $GetParam{FormID},
    );
    # check some values
    foreach (qw(From To Cc Bcc)) {
        if ($GetParam{$_}) {
            foreach my $Email (Mail::Address->parse($GetParam{$_})) {
                if (!$Self->{CheckItemObject}->CheckEmail(Address => $Email->address())) {
                     $Error{"$_ invalid"} .= $Self->{CheckItemObject}->CheckError();
                }
            }
        }
    }
    # --
    # get std attachment ids
    # --
    my @StdAttachmentIDs = $Self->{ParamObject}->GetArray(Param => 'StdAttachmentID');
    # prepare subject
    my $Tn = $Self->{TicketObject}->TicketNumberLookup(TicketID => $Self->{TicketID});
    $GetParam{Subject} = $Self->{TicketObject}->TicketSubjectBuild(
        TicketNumber => $Tn,
        Subject => $GetParam{Subject} || '',
    );
    # rewrap body if exists
    if ($GetParam{Body}) {
        my $NewLine = $Self->{ConfigObject}->Get('ComposeTicketNewLine') || 75;
        $GetParam{Body} =~ s/(^>.+|.{4,$NewLine})(?:\s|\z)/$1\n/gm;
    }
    # prepare free text
    my %TicketFree = ();
    foreach (1..8) {
        $TicketFree{"TicketFreeKey$_"} =  $Self->{ParamObject}->GetParam(Param => "TicketFreeKey$_");
        $TicketFree{"TicketFreeText$_"} =  $Self->{ParamObject}->GetParam(Param => "TicketFreeText$_");
    }
    # get free text config options
    my %TicketFreeText = ();
    foreach (1..8) {
        $TicketFreeText{"TicketFreeKey$_"} = $Self->{TicketObject}->TicketFreeTextGet(
            TicketID => $Self->{TicketID},
            Type => "TicketFreeKey$_",
            Action => $Self->{Action},
            UserID => $Self->{UserID},
        );
        $TicketFreeText{"TicketFreeText$_"} = $Self->{TicketObject}->TicketFreeTextGet(
           TicketID => $Self->{TicketID},
            Type => "TicketFreeText$_",
            Action => $Self->{Action},
            UserID => $Self->{UserID},
        );
    }
    my %TicketFreeTextHTML = $Self->{LayoutObject}->AgentFreeText(
        Config => \%TicketFreeText,
        Ticket => \%TicketFree,
    );
    # --
    # check some values
    # --
    foreach (qw(To Cc Bcc)) {
        if ($GetParam{$_}) {
            foreach my $Email (Mail::Address->parse($GetParam{$_})) {
                if (!$Self->{CheckItemObject}->CheckEmail(Address => $Email->address())) {
                     $Error{"$_ invalid"} .= $Self->{CheckItemObject}->CheckError();
                }
                if ($Self->{SystemAddress}->SystemAddressIsLocalAddress(Address => $Email->address())) {
                    $Error{"$_ invalid"} .= "Can't forward ticket to ".$Email->address()."! It's a local address! Move it Tickets!"
                }
            }
        }
    }

    my %ArticleParam = ();
        # run compose modules
        if (ref($Self->{ConfigObject}->Get('Frontend::ArticleComposeModule')) eq 'HASH') {
            my %Jobs = %{$Self->{ConfigObject}->Get('Frontend::ArticleComposeModule')};
            foreach my $Job (sort keys %Jobs) {
                # log try of load module
                if ($Self->{Debug} > 1) {
                    $Self->{LogObject}->Log(
                        Priority => 'debug',
                        Message => "Try to load module: $Jobs{$Job}->{Module}!",
                    );
                }
                if (eval "require $Jobs{$Job}->{Module}") {
                    my $Object = $Jobs{$Job}->{Module}->new(
                        %{$Self},
                        Debug => $Self->{Debug},
                    );
                    # log loaded module
                    if ($Self->{Debug} > 1) {
                        $Self->{LogObject}->Log(
                            Priority => 'debug',
                            Message => "Module: $Jobs{$Job}->{Module} loaded!",
                        );
                    }
                    # get params
                    foreach ($Object->Option(%GetParam, Config => $Jobs{$Job})) {
                        $GetParam{$_} = $Self->{ParamObject}->GetParam(Param => $_);
                    }
                    # run module
                    $Object->Run(%GetParam, Config => $Jobs{$Job});
                    # ticket params
                    %ArticleParam = (%ArticleParam, $Object->ArticleOption(%GetParam, Config => $Jobs{$Job}));
                    # get errors
                    %Error = (%Error, $Object->Error(%GetParam, Config => $Jobs{$Job}));
                }
                else {
                    $Self->{LogObject}->Log(
                        Priority => 'error',
                        Message => "Can't load module $Jobs{$Job}->{Module}!",
                    );
                }
            }
        }
    # --
    # check if there is an error
    # --
    if (%Error) {
        my $QueueID = $Self->{TicketObject}->TicketQueueID(TicketID => $Self->{TicketID});
        my $Output = $Self->{LayoutObject}->Header(Area => 'Agent', Title => 'Forward');
        $Output .= $Self->_Mask(
            TicketNumber => $Tn,
            TicketID => $Self->{TicketID},
            QueueID => $QueueID,
            NextStates => $Self->_GetNextStates(),
            NextState => $NextState,
            Errors => \%Error,
            Attachments => \@Attachments,
            %TicketFreeTextHTML,
            %GetParam,
        );
        $Output .= $Self->{LayoutObject}->Footer();
        return $Output;
    }
    # replace <OTRS_TICKET_STATE> with next ticket state name
    if ($NextState) {
        $GetParam{Body} =~ s/<OTRS_TICKET_STATE>/$NextState/g;
    }
    # get pre loaded attachments
    my @AttachmentData = $Self->{UploadCachObject}->FormIDGetAllFilesData(
        FormID => $GetParam{FormID},
    );
    # get submit attachment
    my %UploadStuff = $Self->{ParamObject}->GetUploadAll(
        Param => 'file_upload',
        Source => 'String',
    );
    if (%UploadStuff) {
        push (@AttachmentData, \%UploadStuff);
    }
    # send email
    if (my $ArticleID = $Self->{TicketObject}->ArticleSend(
        ArticleTypeID => $Self->{GetParam}->{ArticleTypeID},
        SenderType => 'agent',
        TicketID => $Self->{TicketID},
        HistoryType => 'Forward',
        HistoryComment => "\%\%$GetParam{To}, $GetParam{Cc}, $GetParam{Bcc}",
        From => $GetParam{From},
        To => $GetParam{To},
        Cc => $GetParam{Cc},
        Bcc => $GetParam{Bcc},
        Subject => $GetParam{Subject},
        UserID => $Self->{UserID},
        Body => $GetParam{Body},
        InReplyTo => $GetParam{InReplyTo},
        Charset => $Self->{LayoutObject}->{UserCharset},
        Type => 'text/plain',
        Attachment => \@AttachmentData,
        StdAttachmentIDs => \@StdAttachmentIDs,
        %ArticleParam,
    )) {
        # time accounting
        if ($GetParam{TimeUnits}) {
            $Self->{TicketObject}->TicketAccountTime(
                TicketID => $Self->{TicketID},
                ArticleID => $ArticleID,
                TimeUnit => $GetParam{TimeUnits},
                UserID => $Self->{UserID},
            );
        }
        # update ticket free text
        foreach (1..8) {
            my $FreeKey = $Self->{ParamObject}->GetParam(Param => "TicketFreeKey$_");
            my $FreeValue = $Self->{ParamObject}->GetParam(Param => "TicketFreeText$_");
            if (defined($FreeKey) && defined($FreeValue)) {
                $Self->{TicketObject}->TicketFreeTextSet(
                    Key => $FreeKey,
                    Value => $FreeValue,
                    Counter => $_,
                    TicketID => $Self->{TicketID},
                    UserID => $Self->{UserID},
                );
            }
        }
        # set state
        $Self->{TicketObject}->StateSet(
            TicketID => $Self->{TicketID},
            ArticleID => $ArticleID,
            State => $NextState,
            UserID => $Self->{UserID},
        );
        # should I set an unlock?
        if ($StateData{TypeName} =~ /^close/i) {
            $Self->{TicketObject}->LockSet(
                TicketID => $Self->{TicketID},
                Lock => 'unlock',
                UserID => $Self->{UserID},
            );
        }
        # set pending time
        elsif ($StateData{TypeName} =~ /^pending/i) {
            $Self->{TicketObject}->TicketPendingTimeSet(
                UserID => $Self->{UserID},
                TicketID => $Self->{TicketID},
                Year => $GetParam{Year},
                Month => $GetParam{Month},
                Day => $GetParam{Day},
                Hour => $GetParam{Hour},
                Minute => $GetParam{Minute},
            );
        }
        # remove pre submited attachments
        $Self->{UploadCachObject}->FormIDRemove(FormID => $GetParam{FormID});
        # redirect
        if ($StateData{TypeName} =~ /^close/i) {
            return $Self->{LayoutObject}->Redirect(OP => $Self->{LastScreenOverview});
        }
        else {
            return $Self->{LayoutObject}->Redirect(OP => $Self->{LastScreenView});
        }
    }
    else {
      # error page
      $Output .= $Self->{LayoutObject}->Header(Title => 'Forward');
      $Output .= $Self->{LayoutObject}->Error(
          Comment => 'Please contact the admin.',
      );
      $Output .= $Self->{LayoutObject}->Footer();
      return $Output;
    }
}
# --
sub _GetNextStates {
    my $Self = shift;
    my %Param = @_;
    # get next states
    my %NextStates = $Self->{TicketObject}->StateList(
        Type => 'DefaultNextForward',
        Action => $Self->{Action},
        TicketID => $Self->{TicketID},
        UserID => $Self->{UserID},
    );
    return \%NextStates;
}
# --
sub _Mask {
    my $Self = shift;
    my %Param = @_;
    # build next states string
    $Param{'NextStatesStrg'} = $Self->{LayoutObject}->OptionStrgHashRef(
        Data => $Param{NextStates},
        Name => 'ComposeStateID',
        Selected => $Param{NextState}
    );
    my %ArticleTypes = ();
    my @ArticleTypesPossible = @{$Self->{ConfigObject}->Get('DefaultForwardEmailType')};
    foreach (@ArticleTypesPossible) {
        $ArticleTypes{$Self->{TicketObject}->ArticleTypeLookup(ArticleType => $_)} = $_;
    }
    if ($Self->{GetParam}->{ArticleTypeID}) {
        $Param{'ArticleTypesStrg'} = $Self->{LayoutObject}->OptionStrgHashRef(
            Data => \%ArticleTypes,
            Name => 'ArticleTypeID',
            SelectedID => $Self->{GetParam}->{ArticleTypeID},
        );
    }
    else {
        $Param{'ArticleTypesStrg'} = $Self->{LayoutObject}->OptionStrgHashRef(
            Data => \%ArticleTypes,
            Name => 'ArticleTypeID',
            Selected => $Self->{ConfigObject}->Get('DefaultForwardEmailTypeSelected'),
        );
    }

    # create FromHTML (to show)
    $Param{FromHTML} = $Self->{LayoutObject}->Ascii2Html(Text => $Param{From}, Max => 70);
    # do html quoting
    foreach (qw(ReplyTo From To Cc Bcc Subject Body)) {
        $Param{$_} = $Self->{LayoutObject}->Ascii2Html(Text => $Param{$_}) || '';
    }
    # prepare errors!
    if ($Param{Errors}) {
        foreach (keys %{$Param{Errors}}) {
            $Param{$_} = "* ".$Self->{LayoutObject}->Ascii2Html(Text => $Param{Errors}->{$_});
        }
    }
    # pending data string
    $Param{PendingDateString} = $Self->{LayoutObject}->BuildDateSelection(
        %Param,
        Format => 'DateInputFormatLong',
        DiffTime => $Self->{ConfigObject}->Get('PendingDiffTime') || 0,
    );
    # show attachments
    foreach my $DataRef (@{$Param{Attachments}}) {
        $Self->{LayoutObject}->Block(
            Name => 'Attachment',
            Data => $DataRef,
        );
    }
    # create & return output
    return $Self->{LayoutObject}->Output(TemplateFile => 'AgentForward', Data => \%Param);
}
# --
1;
