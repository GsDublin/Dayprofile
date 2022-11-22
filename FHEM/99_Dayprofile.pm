# $Id: 99_Dayprofile.pm 
####################################################################################################
#
#   Dayprofile
#   BitSpeicher speichert einzelne Bits an bestimmten Positionen
#   Die Nutzdaten werden als HEX String abgelegt
#
#
####################################################################################################

####################################################################################################
# define DP_localhost_presence Dayprofile pres_localhost.presence:.present pres_localhost.presence:.absent
# define DP_localhost_presence Dayprofile pres_localhost.presence:.present 
# define DP_presence Dayprofile [.*]
# define DP_Flur_EG_Lampe_PIR1 Dayprofile Haus_EG_Flurlampe1:d_motion
####################################################################################################

####################################################################################################
#
####################################################################################################

package main;
use strict;
use warnings;
use vars qw(%defs);
use vars qw($readingFnAttributes);
use vars qw(%attr);
use vars qw(%modules);
##my $Dayprofile_Version = "DYVND 0.0.0.1 - 22.04.2021";
my $Dayprofile_Version = "DYVND 0.0.0.2 - 21.11.2022";

my @Dayprofile_cmdQeue = ();
my $hexstring = "";

my $DEBUG = 1;

my %gets = (
  "protocol" => undef,
  "update" => undef
);

##########################
sub Dayprofile_Log($$$)
{
  my ( $hash, $loglevel, $text ) = @_;
  my $xline       = ( caller(0) )[2];
  my $xsubroutine = ( caller(1) )[3];
  my $sub         = ( split( ':', $xsubroutine ) )[2];
  $sub =~ s/Dayprofile_//;
  my $instName = ( ref($hash) eq "HASH" ) ? $hash->{NAME} : "Dayprofile";
  Log3 $hash, $loglevel, "Dayprofile $instName $sub.$xline " . $text;
}
##########################
sub Dayprofile_Initialize($)
{
  my ($hash) = @_;
  ##$hash->{parseParams} = 1;
  $hash->{DefFn}                    =   "Dayprofile_Define";
  $hash->{UndefFn}                  =   "Dayprofile_Undef";
  $hash->{SetFn}                    =   "Dayprofile_Set";
  $hash->{GetFn}                    =   "Dayprofile_Get";
  $hash->{NotifyFn}                 =   "Dayprofile_Notify";
  $hash->{AttrFn}                   =   "Dayprofile_Attr";
  $hash->{AttrList}                 =   "disable:0,1 " .
                                        "prefix " .
                                        "resolutionPrefix:0,1 " .
                                        "suffix " .
                                        "resolutionSuffix:0,1 " .
                                        "add_dp " .                                      ## shows additional dp / dayprofile reading with diffrent seconds/bit (comma separated list of resolutions)
                                        "add_protocol " .                                ## shows additional summary of events like HH:MM:SS\n ...
                                        "and_device " .                                  ## profile(s) for binary AND function
                                        "or_device " .                                   ## profile(s) for binary OR function
                                        "secondsBit " . 
                                        "ReadingDestination:DPDevice,ReadingDevice " .
                                        $readingFnAttributes;
                                        
  Dayprofile_Log "", 3, "Init Done with Version $Dayprofile_Version";
}
##########################
sub Dayprofile_Define($$$)
{
  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );
  my $name = $a[0];
  Dayprofile_Log $hash, ($DEBUG) ? 0 : 4, "parameters: @a";
  if ( @a < 3 )
  {
    return "wrong syntax: define <name> Dayprofile <regexp_for_ON> [<regexp_for_OFF>]";
  }
  my $onRegexp = $a[2];
  my $offRegexp = ( @a == 4 ) ? $a[3] : undef;

  # Checking for misleading regexps
  eval { "Hallo" =~ m/^$onRegexp/ };
  return "Bad regexp_for_ON : $@" if ($@);
  if ($offRegexp)
  {
    eval { "Hallo" =~ m/^$offRegexp/ };
    return "Bad regexp_for_ON : $@" if ($@);
  }

  #
  # some inits
  $hash->{VERSION}                  = $Dayprofile_Version;
  $hash->{helper}{ON_Regexp}        = $onRegexp;
  $hash->{helper}{OFF_Regexp}       = $offRegexp;
  $hash->{helper}{isFirstRun}       = 1;
  $hash->{helper}{value}            = -1;
  $hash->{helper}{forceHourChange}  = '';
  $hash->{helper}{forceDayChange}   = '';
  $hash->{helper}{Hex}           = '';
  $hash->{helper}{forceMonthChange} = '';
  $hash->{helper}{forceYearChange}  = '';
  $hash->{helper}{forceClear}       = '';
  $hash->{helper}{forceUpdate}      = '';
  $hash->{helper}{calledByEvent}    = '';
  $hash->{helper}{changedTimestamp} = '';
  $hash->{editFileList};
  @{ $hash->{helper}{cmdQueue} } = ();
  $modules{Dayprofile}{defptr}{$name} = $hash;
  RemoveInternalTimer($name);

  # wait until alle readings have been restored
  InternalTimer( int( gettimeofday() + 15 ), "Dayprofile_Run", $name, 0 );
  return undef;
}
##########################
sub Dayprofile_Undef($$)
{
  my ( $hash, $arg ) = @_;
  Dayprofile_Log $hash, 3, "Done";
  return undef;
}
###########################
sub Dayprofile_Get($@)
{
  my ( $hash, @a ) = @_;
  my $name = $hash->{NAME};
  my $ret  = "Unknown argument $a[1], choose one of version:noArg protocol:noArg";
  my $cmd  = lc( $a[1] );
  if ( $cmd eq 'version' )
  {
    $ret = "Version       : $Dayprofile_Version\n";
  }
  if ( $cmd eq 'protocol' )
  {
    my $binstring = Dayprofile_Hex2Bin($hexstring);
    $ret = Dayprofile_getProtocol($binstring);
  }
  return $ret;
}
###########################
sub Dayprofile_Set($@)
{
  my ( $hash, @a ) = @_;
  my $name  = $hash->{NAME};
  my $reINT = '^([\\+,\\-]?\\d+$)';    # int

  # determine userReadings beginning with app
  my @readingNames = keys( %{ $hash->{READINGS} } );
  my @userReadings = ();
  foreach (@readingNames)
  {
    if ( $_ =~ m/app.*/ )
    {
      push( @userReadings, $_ );
    }
  }
  my $strUserReadings = join( " ", @userReadings ) . " ";

  # standard commands with parameter
  my @cmdPara                       =   (
                                        "HHMMSS",
                                        "Hex",
                                        );

  # standard commands with no parameter
  my @cmdNoPara                     =   (
                                        "clear",
                                        "update",
                                        "forceDayChange",
                                        );
                                            
  my @allCommands =                     (
                                        @cmdPara,
                                        @cmdNoPara,
                                        @userReadings
                                        );
                                        
  my $strAllCommands =
    join( " ", ( @cmdPara, @userReadings ) ) . " " . join( ":noArg ", @cmdNoPara ) . ":noArg ";

  #Dayprofile_Log $hash, 2, "strAllCommands : $strAllCommands";
  # stop:noArg
  my $usage = "Unknown argument $a[1], choose one of " . $strAllCommands;

  # we need at least 2 parameters
  return "Need a parameter for set" if ( @a < 2 );
  my $cmd = $a[1];
  if ( $cmd eq "?" )
  {
    return $usage;
  }
  my $value = $a[2];

  # is command defined ?
  if ( ( grep { /$cmd/ } @allCommands ) <= 0 )
  {
    Dayprofile_Log $hash, 2, "cmd:$cmd no match for : @allCommands";
    return return "unknown command : $cmd";
  }

  # need we a parameter ?
  my $hits = scalar grep { /$cmd/ } @cmdNoPara;
  my $needPara = ( $hits > 0 ) ? '' : 1;
  Dayprofile_Log $hash, 4, "hits: $hits needPara:$needPara";

  # if parameter needed, it must be an integer
  return "Value must be an integer" if ( $needPara && !( $value =~ m/$reINT/ ) );
  my $info = "command : " . $cmd;
  $info .= " " . $value if ($needPara);
  Dayprofile_Log $hash, 4, $info;
  my $doRun = '';
  if ($needPara)
  {
    readingsSingleUpdate( $hash, $cmd, $value, 1 );
  } elsif ( $cmd eq "forceDayChange" )
  {
    $hash->{helper}{forceDayChange} = 1;
    $doRun = 1;
  } elsif ( $cmd eq "Hex" )
  {
    $hash->{helper}{Hex} = 1;
    $doRun = 1;
  } elsif ( $cmd eq "clear" )
  {
    $hash->{helper}{forceClear} = 1;
    $doRun = 1;
  } elsif ( $cmd eq "update" )
  {
    $hash->{helper}{forceUpdate} = 1;
    $doRun = 1;
  } elsif ( $cmd eq "calc" )
  {
    $doRun = 1;
  } else
  {
    return "unknown command (2): $cmd";
  }

  # perform run
  if ( $doRun && !$hash->{helper}{isFirstRun} )
  {
    $hash->{helper}{value}         = -1;
    $hash->{helper}{calledByEvent} = 1;
    Dayprofile_Run( $hash->{NAME} );
  }
  return;
}
##########################
sub Dayprofile_Notify($$)
{
  my ( $hash, $dev ) = @_;
  my $name    = $hash->{NAME};
  my $devName = $dev->{NAME};

  # return if disabled
  if ( AttrVal( $name, 'disable', '0' ) eq '1' )
  {
    return "";
  }
  my $onRegexp  = $hash->{helper}{ON_Regexp};
  my $offRegexp = $hash->{helper}{OFF_Regexp};
  my $max       = int( @{ $dev->{CHANGED} } );
  for ( my $i = 0 ; $i < $max ; $i++ )
  {
    my $s = $dev->{CHANGED}[$i];    # read changed reading
    $s = "" if ( !defined($s) );
    my $isOnReading = ( "$devName:$s" =~ m/^$onRegexp$/ );
    my $isOffReading = ($offRegexp) ? ( "$devName:$s" =~ m/^$offRegexp$/ ) : '';

    # Dayprofile_Log $hash, 5, "devName:$devName; CHANGED:$s; isOnReading:$isOnReading; isOffReading:$isOffReading;";
    next if ( !( $isOnReading || ( $isOffReading && $offRegexp ) ) );
    $hash->{helper}{value} = 1 if ($isOnReading);
    $hash->{helper}{value} = 0 if ($isOffReading);
    $hash->{helper}{calledByEvent} = 1;
    if ( !$hash->{helper}{isFirstRun} )
    {
      Dayprofile_Run( $hash->{NAME} );
    }
  }
}
##########################
sub Dayprofile_Attr($$$$)
{
  my ( $command, $name, $attribute, $value ) = @_;
  my $msg  = undef;
  my $hash = $defs{$name};
  if ( $attribute eq "interval" )
  {
    #Dayprofile_Log $hash, 0, "cmd:$command name:$name attribute:$attribute";
    if ( !$hash->{helper}{isFirstRun} )
    {
      Dayprofile_Run($name);
    }
  }
  return $msg;
}
##########################
sub Dayprofile_AddLog($$$)
{
  my ( $logdevice, $readingName, $value ) = @_;
  my $cmd = '';
  if ( $readingName =~ m,state,i )
  {
    $cmd = "trigger $logdevice $value   << addLog";
  } else
  {
    $cmd = "trigger $logdevice $readingName: $value   << addLog";
  }
  Dayprofile_Log '', 3, $cmd;
  fhem($cmd);
}
##########################
# execute the content of the given parameter
sub Dayprofile_Exec($)
{
  my $doit = shift;
  my $ret  = '';
  eval $doit;
  $ret = $@ if ($@);
  return $ret;
}
##########################
# add command to queue
sub Dayprofile_cmdQueueAdd($$)
{
  my ( $hash, $cmd ) = @_;
  push( @{ $hash->{helper}{cmdQueue} }, $cmd );
}
##########################
# execute command queue
sub Dayprofile_ExecQueue($)
{
  my ($hash) = @_;
  my $result;
  my $cnt    = $#{ $hash->{helper}{cmdQueue} };
  my $loops  = 0;
  my $cntAll = 0;
  Dayprofile_Log $hash, 4, "cnt: $cnt";
  while ( $cnt >= 0 )
  {

    for my $i ( 0 .. $cnt )
    {
      my $cmd = ${ $hash->{helper}{cmdQueue} }[$i];
      ${ $hash->{helper}{cmdQueue} }[$i] = '';
      $result = Dayprofile_Exec($cmd);
      if ($result)
      {
        Dayprofile_Log $hash, 2, "$result";
      } else
      {
        Dayprofile_Log $hash, 4, "exec ok:$cmd";
      }
      $cntAll++;
    }

    # bearbeitete eintraege loeschen
    for ( my $i = $cnt ; $i > -1 ; $i-- )
    {
      splice( @{ $hash->{helper}{cmdQueue} }, $i, 1 );
    }
    $cnt = $#Dayprofile_cmdQeue;
    $loops++;
    if ( $loops >= 5 || $cntAll > 100 )
    {
      Dayprofile_Log $hash, 2, "!!! too deep recursion";
      last;
    }
  }
}
##########################
# round off the date passed to the hour
sub Dayprofile_RoundHour($)
{
  my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime(shift);
  return mktime( 0, 0, $hour, $mday, $mon, $year );
}
##########################
# round off the date passed to the day
sub Dayprofile_RoundDay($)
{
  my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime(shift);
  return mktime( 0, 0, 0, $mday, $mon, $year );
}
##########################
# round off the date passed to the week
sub Dayprofile_RoundWeek($)
{
  my ($time) = @_;
  my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime($time);

  # wday 0 Sonntag 1 Montag ...
  $time -= $wday * 86400;
  return Dayprofile_RoundDay($time);
}
##########################
# returns the seconds since the start of the day
sub Dayprofile_SecondsOfDay()
{
  my $timeToday = gettimeofday();
  return int( $timeToday - Dayprofile_RoundDay($timeToday) );
}
##########################
# round off the date passed to the month
sub Dayprofile_RoundMonth($)
{
  my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime(shift);
  return mktime( 0, 0, 0, 1, $mon, $year );
}
##########################
# round off the date passed to the year
sub Dayprofile_RoundYear($)
{
  my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime(shift);
  return mktime( 0, 0, 0, 1, 1, $year );
}
##########################
# converts the seconds in the date format
sub Dayprofile_Seconds2HMS($)
{
  my ($seconds) = @_;
  my ( $Sekunde, $Minute, $Stunde, $Monatstag, $Monat, $Jahr, $Wochentag, $Jahrestag, $Sommerzeit ) =
    localtime($seconds);
  my $days = int( $seconds / 86400 );
  return sprintf( "%d Tage %02d:%02d:%02d", $days, $Stunde - 1, $Minute, $Sekunde );
}
##########################
# rounds the timestamp do the beginning of the week
sub Dayprofile_weekBase($)
{
  my ($time) = @_;
  my $dayDiff = 60 * 60 * 24;
  my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime($time);

  # wday 0 Sonntag 1 Montag ...
  my $a = $time - $wday * $dayDiff;
  my $b = int( $a / $dayDiff );       # auf tage gehen
  my $c = $b * $dayDiff;
  return $c;
}
##########################
# this either called by timer for cyclic update
# or it is called by an event (on/off)
sub Dayprofile_Run($)
{
    # print "xxx TAG A\n" ;
    my ($name) = @_;
    my $hash = $defs{$name};
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

    # must be of type Dayprofile
    return if ( !defined( $hash->{TYPE} ) || $hash->{TYPE} ne 'Dayprofile' );

    # timestamps for event-log-file-entries, older than current time
    delete( $hash->{CHANGETIME} );

    # flag for called by event
    my $calledByEvent = $hash->{helper}{calledByEvent};

    # reset flag
    $hash->{helper}{calledByEvent} = '';

    # if call was made by timer, than force value to -1
    my $valuePara = ($calledByEvent) ? $hash->{helper}{value} : -1;

    # initialize changedTimestamp, if it does not exist
    $hash->{helper}{changedTimestamp} = ReadingsTimestamp( $name, "value", TimeNow() )
    if ( !$hash->{helper}{changedTimestamp} );

    # serial date for changed timestamp
    my $sdValue      = time_str2num( $hash->{helper}{changedTimestamp} );
    my $sdCurTime    = gettimeofday();
    my $isOffDefined = ( $hash->{helper}{OFF_Regexp} ) ? 1 : '';

    # calc time diff
    my $timeIncrement = int( $sdCurTime - $sdValue );

    # wrong time offset in case of summer/winter time
    $timeIncrement = 0 if ( $timeIncrement < 0 );

    # get the old value
    my $valueOld = ReadingsVal( $name, 'value', 0 );

    # variable for reading update
    my $value = undef;

    ## get attributes
    my $add_dp              = AttrVal( $name, 'add_dp'              , '' );
    my $secondsBit          = AttrVal( $name, 'secondsBit'          , 300 );
    my $prefix              = AttrVal( $name, 'prefix'              , '' );
    my $resolutionPrefix    = AttrVal( $name, 'resolutionPrefix'    , 0 );
    my $suffix              = AttrVal( $name, 'suffix'              , '' );
    my $resolutionSuffix    = AttrVal( $name, 'resolutionSuffix'    , 0 );
    my $and_device          = AttrVal( $name, 'and_device'          , '' );
    my $or_device           = AttrVal( $name, 'or_device'           , '' );
    my $add_protocol        = AttrVal( $name, 'add_protocol'        , 0 );

    if ( ! $resolutionPrefix ) {
        $resolutionPrefix = '';
    } else {
        $resolutionPrefix = "$secondsBit";
    }

    if ( ! $resolutionSuffix ) {
        $resolutionSuffix = '';
    } else {
        $resolutionSuffix = "$secondsBit";
    }
    

    my $hex_reading_name = $prefix . $resolutionPrefix . "hex" . $resolutionSuffix . $suffix;
    $hexstring  = ReadingsVal( $name, $hex_reading_name, "" );
    my $secondsBit_hex = Dayprofile_getHexResolution( $hexstring );


    my $tickUpdated = ReadingsVal( $name, "tickUpdated", 0 ) + 1;
    $tickUpdated = 1 if ( $tickUpdated >= 1000 );

    my $tickChanged = ReadingsVal( $name, "tickChanged", 0 );
    my $tickDay     = ReadingsVal( $name, "tickDay",     0 );

    my $state = '';

    ##my $sdTickHour = time_str2num( ReadingsTimestamp( $name, "tickHour", TimeNow() ) );
    my $sdHexTimestamp = time_str2num( ReadingsTimestamp( $name, $hex_reading_name, TimeNow() ) );

    # serial date for current hour
    my $sdRoundHour = Dayprofile_RoundHour($sdCurTime);

    ##my $sdRoundHourLast = Dayprofile_RoundHour($sdTickHour);
    my $sdRoundHourLast = Dayprofile_RoundHour($sdHexTimestamp);
    $sdRoundHourLast = $sdRoundHour if ( !$sdRoundHourLast );
    my $isHourChanged = ( $sdRoundHour != $sdRoundHourLast ) || $hash->{helper}{forceHourChange};

    # serial date for current day
    my $sdRoundDayCurTime = Dayprofile_RoundDay($sdCurTime);
    my $sdRoundDayValue   = Dayprofile_RoundDay($sdRoundHourLast);
    ##Dayprofile_Log $hash, 0, "sdCurTime:$sdCurTime";
    ##Dayprofile_Log $hash, 0, "sdRoundHourLast:$sdRoundHourLast";
    ##Dayprofile_Log $hash, 0, "sdRoundDayCurTime:$sdRoundDayCurTime";
    ##Dayprofile_Log $hash, 0, "sdRoundDayValue:$sdRoundDayValue";
    my $isDayChanged      = ( $sdRoundDayCurTime != $sdRoundDayValue ) || $hash->{helper}{forceDayChange};


    # loop forever
    while (1)
    {
        # stop if disabled
        last if ( AttrVal( $name, 'disable', '0' ) eq '1' );

        # variables for controlling
        Dayprofile_Log $hash, 5, "value:$valuePara changedTimestamp:" . $hash->{helper}{changedTimestamp};

        ##########################################################################################
        # ------------ basic init, when first run
        if ( $hash->{helper}{isFirstRun} )
        {
          $hash->{helper}{isFirstRun}      = undef;
          $hash->{helper}{sdRoundHourLast} = $sdRoundHourLast;

          # first init after startup
          readingsBeginUpdate($hash);
          ##readingsBulkUpdate( $hash, 'tickHour',  0 );
          readingsEndUpdate( $hash, 0 );

          # set initial values
          $value         = $valueOld;    # value als reading anlegen falls nicht vorhanden
          $timeIncrement = 0;

          ##Dayprofile_Log $hash, 5, "first run done countsOverall:" . $countsOverall;    #4
        }

        ##########################################################################################
        # -------- force clear request
        if ( $hash->{helper}{forceClear} )
        {
            Dayprofile_Log $hash, 0, "force clear request";
            readingsSingleUpdate( $hash, 'clearDate', TimeNow(), 1 );
          
            readingsBeginUpdate($hash);
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "hex" . $resolutionSuffix . $suffix, '' );
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "dp" . $resolutionSuffix . $suffix, '' );
            readingsBulkUpdate( $hash, 'state', 'clear' );
            
            ## additional dayprofiles
            if ( $add_dp ne '' ) {
                my @add_dp_sec = split( /\,/ , $add_dp );
                foreach ( @add_dp_sec ) {
                    ## Instance Variables
                    my $iresolutionPrefix = "";
                    my $iresolutionSuffix = "";
                    
                    if ( ! $resolutionPrefix ) {
                        $iresolutionPrefix = '';
                    } else {
                        $iresolutionPrefix = "$_";
                    }
                    
                    if ( ! $resolutionSuffix ) {
                        $iresolutionSuffix = '';
                    } else {
                        $iresolutionSuffix = "$_";
                    }
                    readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "dp" . $resolutionSuffix . $suffix , '');
                }
            }
            readingsEndUpdate( $hash, 1 );

          # reset all
          $hexstring = "";

          $hash->{helper}{forceClear} = '';
          $timeIncrement = 0;
        }

        ##########################################################################################
        # -------------- handling of transitions
        my $hasValueChanged = 0;
        if ( ( $isOffDefined && $valuePara >= 0 && $valuePara != $valueOld )
          || ( !$isOffDefined && $calledByEvent ) )
        {
            $hasValueChanged = 1;
        }

        ##########################################################################################
        ## if value is 1 (trigged)
        if ($valuePara >= 0) {
            readingsBeginUpdate($hash);
            if ( $secondsBit != $secondsBit_hex ) {
                Dayprofile_Log $hash, 0, "Seconds/Bit is diffrent between Attribute:$secondsBit and Hexstring Resolution:$secondsBit_hex";    #4
            }
             
            if ( $secondsBit_hex <= 0 ) {
                $hexstring = Dayprofile_createHex($secondsBit);
                Dayprofile_Log $hash, 0, "initial create of hexstring [$secondsBit]:" . $hexstring;    #4
            }
            
            my $binstring = Dayprofile_Hex2Bin($hexstring);
            
            my $bit = Dayprofile_calculateBitnumberHHMMSS($hour,$min,$sec,$secondsBit);
            readingsBulkUpdate( $hash, 'lastbit', $bit );
            
            $state = sprintf("%d:%02d:%02d", $hour, $min, $sec );
            readingsBulkUpdate( $hash, 'state', $state );
            
            $binstring = Dayprofile_setBinBit($binstring,$bit);
            
            ## Binary long String to Hex long string
            $hexstring = b2h($binstring);
            
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "hex" . $resolutionSuffix . $suffix, $hexstring );
            
            readingsEndUpdate( $hash, 1 );
        } ## $valuePara >= 0
        
        ##########################################################################################
        ## generate/add additional dayprofiles
        if ( $add_dp ne '' ) {
            readingsBeginUpdate($hash);
            my $binstring = Dayprofile_Hex2Bin($hexstring);
            ##Dayprofile_Log $hash, 0, "additional profiles list: $add_dp";
            my @add_dp_sec = split( /\,/ , $add_dp );
            foreach ( @add_dp_sec ) {
                my $resolution = $_;
                my $dp_binstring = Dayprofile_changeBinResolution( $binstring, $resolution );

                if ( defined $dp_binstring ) {
                    ##Dayprofile_Log $hash, 0, "additional profile: $_";
                    my $dayprofile = Dayprofile_getBinDayprofile($dp_binstring);
                    
                    readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "dp" . $resolutionSuffix . $suffix, $dayprofile );
                } else {
                    Dayprofile_Log $hash, 0, "cannot change resolution for: $_";
                }
            }
            readingsEndUpdate( $hash, 1 );
        }
        
        if ( $add_protocol ) {
            readingsBeginUpdate($hash);
            my $binstring = Dayprofile_Hex2Bin($hexstring);
            my $ret = Dayprofile_getProtocol($binstring);
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "pro" . $resolutionSuffix . $suffix, $ret );
            readingsEndUpdate( $hash, 1 );
        }

        ##########################################################################################
        ## AND profiles
        ################################
        my @and_devices = split( /\,/ , $and_device );
        my @and_hexprofiles;
        foreach ( @and_devices ) {
            my $and_dev = $_;
            Dayprofile_Log $hash, 0, "AND device: $and_dev";
            
            my $iprefix                     = ReadingsVal( $and_dev, 'prefix',              '');
            my $iresolutionPrefix           = ReadingsVal( $and_dev, 'resolutionPrefix',    '');
            my $iresolutionSuffix           = ReadingsVal( $and_dev, 'resolutionSuffix',    '');
            my $isuffix                     = ReadingsVal( $and_dev, 'suffix',              '');
            
            my $ihex_reading_name = $iprefix . $iresolutionPrefix . "hex" . $iresolutionSuffix . $isuffix;
            my $ihex                        = ReadingsVal( $and_dev, $ihex_reading_name,              '');
            
            Dayprofile_Log $hash, 0, "AND device hex reading: $ihex";
            push(@and_hexprofiles, $ihex);
        }
        ##
        ##my $nand_profiles = @and_hexprofiles+0;
        ##if ( $nand_profiles > 0 ) {
        ##    ## find shortest interval
        ##    my $minandres = 0;
        ##    for (my $i=0;$i<$nand_profiles;$i++) {
        ##        if ( $i = 0 ) {
        ##            $minandres = Dayprofile_getHexResolution( $hexstring );
        ##        } else {
        ##            my $ires = Dayprofile_getHexResolution( $hexstring );
        ##            if ( $ires < $minandres ) {
        ##                $minandres = $ires;
        ##            }
        ##        }
        ##    }
        ##    Dayprofile_Log $hash, 0, "shortest resolution of additional AND profiles is: $minandres";
        ##    Dayprofile_Log $hash, 0, "source resolution of hex profile is: $secondsBit_hex";
        ##    
        ##    ## generate binarylongstring for all AND profiles with shortest resolution
        ##    my @and_binprofiles;
        ##    foreach ( @and_devices ) {
        ##        my $ibinstring = Dayprofile_Hex2Bin( $hexstring );
        ##        $ibinstring = Dayprofile_changeBinResolution( $ibinstring, $minandres );
        ##        if ( defined $ibinstring ) {
        ##            Dayprofile_Log $hash, 0, "AND binstring[$minandres]: $ibinstring";
        ##            push( @and_binprofiles, $ibinstring );
        ##        } else {
        ##            Dayprofile_Log $hash, 0, "cannot change resolution for: $_";
        ##        }
        ##    }
        ##}
        ############################################################################################
        ##
        ############################################################################################
        #### OR profiles
        ##################################
        ##my @or_profile_ary = split( /\,/ , $or_device );
        ##my @or_hexprofiles;
        ####
        #### ToDo
        ####
        ############################################################################################

        $hash->{helper}{changedTimestamp} = TimeNow();

        $value = $valueOld;

        # ---------update readings, if vars defined
        readingsBeginUpdate($hash);

        if ($isOffDefined)
        {
          ##readingsBulkUpdate( $hash, "pulseTimeIncrement", $pulseTimeIncrement );
        }
        readingsBulkUpdate( $hash, "value",       $value );
        ##readingsBulkUpdate( $hash, 'state',       $state );
        readingsBulkUpdate( $hash, 'tickUpdated', $tickUpdated );
        readingsEndUpdate( $hash, 1 );

        # --------------- fire time interval ticks for hour,day,month

        if ($hasValueChanged)
        {
            ##$tickChanged++;
            ##$tickChanged = 1 if ( $tickChanged >= 1000 );
            ##readingsSingleUpdate( $hash, 'tickChanged', $tickChanged, 1 );
            ##Dayprofile_Log $hash, 4, 'tickChanged fired ';
        }
        if ($isDayChanged)
        {
            $tickDay++;
            $tickDay = 1 if ( $tickDay >= 1000 );
            $hash->{helper}{forceDayChange} = '';
            readingsSingleUpdate( $hash, 'tickDay', $tickDay, 1 );
            ##Dayprofile_Log $hash, 4, "tickDay fired";
            Dayprofile_Log $hash, 0, "tickDay fired";
        }

        # execute command queue
        Dayprofile_ExecQueue($hash);

        # day change, so reset day readings
        if ($isDayChanged)
        {
            my $ibinstring = Dayprofile_Hex2Bin($hexstring);
            my $idayprofile = Dayprofile_getBinDayprofile($ibinstring);
            
            ### reset all day counters
            readingsBeginUpdate($hash);
            ## set state
            readingsBulkUpdate( $hash, 'state', 'new day' );
            ## save yesterday
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "yhex" . $resolutionSuffix . $suffix, $hexstring );
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "ydp" . $resolutionSuffix . $suffix, $idayprofile );
            ## clear current values
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "hex" . $resolutionSuffix . $suffix, '' );
            readingsBulkUpdate( $hash, $prefix . $resolutionPrefix . "dp" . $resolutionSuffix . $suffix, '' );
            readingsEndUpdate( $hash, 1 );
            ##Dayprofile_Log $hash, 4, "reset day counters";
            Dayprofile_Log $hash, 0, "reset day counters";
        }
        last;
    }  ## while (1)

    # ------------ calculate seconds until next hour starts
    my $interval = AttrVal( $name, 'interval', '60' );
    my $actTime = int( gettimeofday() );
    #my ( $sec, $min, $hour ) = localtime($actTime);

    # round to next interval
    my $seconds = $interval * 60;
    my $nextHourTime = int( ( $actTime + $seconds ) / $seconds ) * $seconds;

    # calc diff in seconds
    my $nextCall = $nextHourTime - $actTime;
    Dayprofile_Log $hash, 5, "nextCall:$nextCall changedTimestamp:" . $hash->{helper}{changedTimestamp};
    RemoveInternalTimer($name);
    InternalTimer( gettimeofday() + $nextCall, "Dayprofile_Run", $hash->{NAME}, 0 );
    return undef;
}

sub Dayprofile_calculateHHMMSSBitnumber($) {
    my( $second_of_day ) = @_;

    my $p_hour = POSIX::floor( $second_of_day / 3600.0 );
    my $p_min = POSIX::floor( ($second_of_day - ($p_hour * 3600)) / 60.0 );
    my $p_sec = ($second_of_day - ($p_hour * 3600) - ($p_min * 60));

    return sprintf("%02d:%02d:%02d", $p_hour, $p_min, $p_sec);
}

sub Dayprofile_calculateBitnumberHHMMSS($$$$) {
    my($p_hour,$p_min,$p_sec,$secondsBit) = @_;
    ##Log 3, "Dayprofile_calculateBitnumberHHMMSS: $p_hour,$p_min,$p_sec,$secondsBit";
    
    if ($secondsBit <=0 || $secondsBit >= 65535) {
        Log 3, "Min Resolution <=0:";
        return "Min Resolution <=0";
    }

    my $bitnumber = POSIX::floor(($p_hour * (3600 / $secondsBit)) + (($p_min * 60) / $secondsBit) + ($p_sec / $secondsBit));
    my $bytepos = POSIX::floor($bitnumber / 8);
    my $bitpos = $bitnumber % 8;

    return $bitnumber;
}

## Calculates the Timestamt of given Bit with given Resolution
## bitnumber  e.g. 170
## secondsBit e.g. 300
sub Dayprofile_calculateSSS($$) {
    my($bitnumber,$secondsBit) = @_;
    my $second_of_day = $bitnumber/((24*3600)/$secondsBit)*(24*3600);
    return $second_of_day;
}
 
sub Dayprofile_setBinBit($$) {
    my($p_binstring,$p_bit) = @_;
    
    if ( length($p_binstring) >= $p_bit ) {
        substr($p_binstring,$p_bit,1) = "1";
    } else {
        Log 3, "Length of binstring is to short for the bit $p_bit";
    }
    
    return $p_binstring;
}


sub Dayprofile_changeBinResolution($$) {
    my($p_binstring,$p_tintervall) = @_;
    my $i;
    
    
    if (length($p_binstring) <= 0 ) {
        Log 3, "empty binstring";
        return undef;
    }
    
    my $secondsBit = POSIX::ceil((24*3600)/(length($p_binstring)));
    if ($secondsBit > $p_tintervall) {
        Log 3, "Target interval is smaller than source intervall. Using source intervall.";
        ##$p_tintervall = $secondsBit;
        return $p_binstring;
    }
    if ($secondsBit == $p_tintervall) {
        return $p_binstring;
    }
    
    my $gear = POSIX::floor($p_tintervall / $secondsBit);
    if ($gear <= 1) { return undef;}
    my $len = length($p_binstring)-$gear;
    my $tbinstring = "";
    
    if ($len>0) {
        for ($i=0;$i<$len;$i+=$gear) {
            my $src = substr($p_binstring,$i,$gear);
            my $bin0 = "0" x length($src);
            
            $tbinstring .= ( $src eq $bin0 ) ? "0" : "1";
        }
    }
    
    return $tbinstring;
}

sub Dayprofile_Bin2Hex($)
{
    my($p_binstring) = @_;
    my $int = unpack("N", pack("B32", substr("0" x 32 . $p_binstring, -32)));
    my $hexstring = sprintf("%x", $int );
    
    return $hexstring;
}

sub Dayprofile_Hex2Bin($)
{
    my($p_hexstring) = @_;
    my $i;
    my @hexarray=( $p_hexstring=~ m/..?/g );
    my $nbytes = @hexarray+0;
    
    if ($nbytes<=0) {
        Log 3, "Dayprofile Dayprofile_Hex2Bin nbytes to small. $nbytes<=0";
        Log 3, "Dayprofile Dayprofile_Hex2Bin p_hexstring: $p_hexstring";
        return (undef);
    }
    
    ##Log 3, "Dayprofile  Dayprofile_Hex2Bin nbytes: $nbytes";
    
    ## Jedes Byte in Dezimal umwandeln und als 8 Bit Binärstring anketten
    my @bits;
    for ($i=0;$i<$nbytes;$i++) {
        my $bin = sprintf("%08b", hex($hexarray[$i]));
        push(@bits, $bin);
    }
    ## string mit allen bits
    return join('', @bits);
}

sub Dayprofile_getBinDayprofile($)
{
    my( $p_binstring ) = @_;
    my $bit_h = POSIX::ceil( length($p_binstring) / 24 );
    
    my $dayprofile = "";
    
    for (my $i = 0; $i < 24; $i++) {
        $dayprofile .= sprintf("%02d",$i) . ":00 ";
        $dayprofile .= substr($p_binstring, $i * $bit_h, $bit_h);
        $dayprofile .= "\n";
        
    }
    return $dayprofile;
}

sub Dayprofile_getProtocol($)
{
    my( $p_binstring ) = @_;
    if (length($p_binstring) <= 0) { return "no binstring";}
    my $secondsBit = POSIX::ceil((24*3600)/(length($p_binstring)));
    
    ##my $protocol = "${secondsBit}:${p_binstring}";
    my $protocol = "";
    if ($secondsBit <= 0) { return "secondsBit invalid";}
    
    for (my $i = 0; $i < length($p_binstring); $i++) {
        if (substr($p_binstring, $i, 1) eq "1") {
            my $sss = Dayprofile_calculateSSS($i, $secondsBit);
            my $HHMMSS = Dayprofile_calculateHHMMSSBitnumber($sss);
            if ( $secondsBit > 60 ) {
                $HHMMSS = substr($HHMMSS, 0, 5);
            } 
            $protocol .= "${HHMMSS}\n";
        }
    }
    
    return $protocol;
}

sub Dayprofile_getBinResolution($) {
    my($p_binstring) = @_;
    if ( $p_binstring eq "" ) {
        return 0;
    }
    my $secondsBit = POSIX::ceil((24*3600)/(length($p_binstring)));
    return $secondsBit;
}

sub b2h {
    my $num   = shift;
    my $WIDTH = 4;
    my $index = length($num) - $WIDTH;
    my $hex = '';
    do {
        my $width = $WIDTH;
        if ($index < 0) {
            $width += $index;
            $index = 0;
        }
        my $cut_string = substr($num, $index, $width);
        $hex = sprintf('%X', oct("0b$cut_string")) . $hex;
        $index -= $WIDTH;
    } while ($index > (-1 * $WIDTH));
    return $hex;
}

###############################################################################################
#
#                 HEX FUNCTIONS
#
###############################################################################################

## 20210420 DY
sub Dayprofile_getHexResolution($) {
    my($p_hexstring) = @_;
    if ( $p_hexstring eq "" ) {
        return 0;
    }
    my $bits = POSIX::ceil((24*3600)/((length($p_hexstring)/2)*8));
    return $bits;
}

sub Dayprofile_createHex($)
{
    my($secondsBit) = @_;
    my @hexarray;
    my $offset=2;
    my $i;

    my $nbytes= POSIX::ceil((24*(3600/$secondsBit)) / 8);

    for($i=0;$i<$nbytes;$i++) {
        $hexarray[$i]="00";
    }

    my $hexstring = join('',@hexarray);
    return $hexstring;
}

sub Dayprofile_setHexBit($$)
{
    my($p_hexstring,$p_bit) = @_;
    my $i;
    my @hexarray=( $p_hexstring=~ m/..?/g ); ## Je zwei Zeichen in ein Arraybyte splitten

    my $secondsBit = Dayprofile_getHexResolution( $p_hexstring );
    
    if ($secondsBit <=0 || $secondsBit >= 65535) {
        Log 3, "Min Resolution <=0:";
        return "Min Resolution <=0";
    }
    my $nbytes= POSIX::ceil((24*3600)/$secondsBit/8);

    my $arraysize = @hexarray+0;
    if($arraysize<($nbytes)) {
        Log 3, "Array to small: ".$arraysize;
        for($i=$arraysize;$i<($nbytes);$i++) {
            $hexarray[$i]="00";
        }
    }

    my $bytepos = POSIX::floor($p_bit / 8);
    my $bitpos = $p_bit % 8;
    $hexarray[$bytepos] = hex($hexarray[$bytepos]);
    $hexarray[$bytepos] |= (0x1 << (7-$bitpos));
    $hexarray[$bytepos] = sprintf("%02X", $hexarray[$bytepos]);

    my $hexstring = join('',@hexarray);

    return "$hexstring";
}

## Erweitern auf Intervall
## Somit kann eine 1Sek Aufzeichnung als 5Min Text ausgegeben werden
sub Dayprofile_showHexText($$)
## hexstring        Hexadezimaler String (Beinhaltet Quellintervall)
## intervall        Zielintervall in Sekunden
{
    my($p_hexstring,$p_tintervall) = @_;
    my $i;
    my $binary="";
    my @hexarray=( $p_hexstring=~ m/..?/g );
    my $offset = 2;

    ## First two Byte are Resolution
    ##my $res_min = hex($hexarray[0] . $hexarray[1]);  ## resolution in minutes
    my $secondsBit = hex($hexarray[0] . $hexarray[1]);  ## resolution in minutes

    if ($secondsBit <=0 || $secondsBit >= 65535) {
        Log 3, "Min Resolution <=0:";
        return "Min Resolution <=0";
    }
    
    if ($p_tintervall < $secondsBit) {
        Log 3, "Target interval is smaller than source intervall. Using source intervall.";
        $p_tintervall = $secondsBit;
        ##return "Target interval is smaller than Resolution Intervall";
    }
    
    ##my $res_bitsph = 60/$res_min;     ## Bits per hour
    ##my $maxbits = 24*60/$res_min;     ## amount of needed bits for 24h
    ##my $maxbytes= POSIX::floor($maxbits / 8);
    my $res_bitsph= 3600/$secondsBit;               ## Bits per hour
    my $maxbits= 24*$res_bitsph;                  ## amount of needed bits for 24h
    my $nbytes= POSIX::ceil($maxbits / 8);

    ## Jedes Byte in Dezimal umwandeln und als 8 Bit Binärstring anketten
    my @bits;
    for ($i=$offset;$i<($nbytes-1+$offset);$i++){
        ##my $bin = reverse(sprintf("%08b", hex($hexarray[$i])));
        my $bin = sprintf("%08b", hex($hexarray[$i]));
        push(@bits, $bin);
    }
    
    ## string mit allen bits
    my $bitstring = join('', @bits);
    
    ## Aufloesung des binstrings ändern
    $bitstring = Dayprofile_changeBinResolution($bitstring,$p_tintervall);
    
    ## Quellstring auf Ausgabeintervall anpassen
    ## hexstring ist 1s und Ausgabe ist 300s
    ## hexstring ist 15s und Ausgabe ist 300s
    ## 0        90        9,0        90        9,0        90        9
    ## 00000000000000000000,00000000000000000000,00000000000000000000
    ## ======== OR ========,======== OR ========,======== OR ========

    ## jede Zeile ist eine Stunde
    for ($i=0;$i<=23;$i++){
        $binary .= sprintf("%02d",$i) . ":00 ";
        $binary .= substr($bitstring, $i*$res_bitsph, $res_bitsph);
        $binary .= "\n";
    }
    
    return $binary;
}

sub Dayprofile_getHexLastTime($)
## hexstring        Hexadezimaler String
{
    my($p_hexstring) = @_;
    my $i;
    my @hexarray=( $p_hexstring=~ m/..?/g );
    
    ## First two Byte are Resolution
    my $bits = hex($hexarray[0] . $hexarray[1]);  ## resolution in minutes

    if ($bits<=0) {
        return "Bits are <=0";
    }

    my $res_bitsph = 60/$bits;     ## Bits per hour
    my $maxbits = 24*60/$bits;     ## amount of needed bits for 24h
    my $maxbytes= POSIX::ceil($bits / 8);         ## needed Arraysize

    my $bitpos=0;
    my $index=-1;
    my $bin;
    for($i=1;$i<($maxbytes+1);$i++) {
        $hexarray[$i] = sprintf("%02X", hex($hexarray[$i]));
        $bin= reverse(sprintf("%08b", hex($hexarray[$i])));
        if ($i>0 &&hex($hexarray[$i]) != 0) {
            $index=$i;
        }
    }

    if ($index <= 0) {
        return "No match";
    }

    my $bytepos=($index-1);
    ##$bin=reverse(sprintf("%08b", hex($hexarray[$index])));
    $bin=sprintf("%08b", hex($hexarray[$index]));

    for($i=0;$i<8;$i++) {
        if (substr($bin, $i, 1) != 0) {
            $bitpos=$i;
        }
    }

    my $bitnumber = ($bytepos*8) + $bitpos;
    my $p_hour = POSIX::floor($bitnumber / $res_bitsph);
    my $p_min = sprintf("%02d",($bitnumber % $res_bitsph) * $bits);

    return "$p_hour:$p_min";
}

1;

##############################################################################
##############################################################################
##
## Documentation
##
##############################################################################
##############################################################################
=pod

=item summary   send and receive of messages through telegram instant messaging
=item summary_DE senden und empfangen von Nachrichten durch telegram IM
=begin html

=begin html

<p><a name="Dayprofile"></a></p>
<h3>Dayprofile</h3>
<p><u><strong>Dayprofile - storage buffer for events</strong></u></p>
<ul>
<ul>
<ul>This module stores timebased events within an hex orientaded string.</ul>
</ul>
</ul>
<p style="padding-left: 120px;">Each bit represents a "timeslot" marker for the event.</p>
<p>Dayprofile:</p>
<p><code>00:00 000000000000<br />
01:00 000000000000<br />
02:00 000000000000<br />
03:00 000000000000<br />
04:00 000000000000<br />
05:00 000000000000<br />
06:00 000000000000<br />
07:00 000000000000<br />
08:00 000000000000<br />
09:00 000000000000<br />
10:00 000000000000<br />
11:00 000000000000<br />
12:00 000001010001<br />
13:00 000000000000<br />
14:00 000000000000<br />
15:00 000000000000<br />
16:00 000000000000<br />
17:00 000000000000<br />
18:00 000000000000<br />
19:00 000000000000<br />
20:00 000000000000<br />
21:00 000000000000<br />
22:00 000000000000<br />
23:00 000000000000</code></p>
<p>Protocol:<br /><code>12:25<br />
12:35<br />
12:55<br /></code></p>
<p><br /><br /><a name="Dayprofile_define"></a><strong>Define</strong></p>
<p><code>define &lt;name&gt; Dayprofile &lt;pattern_for_ON&gt; [&lt;pattern_for_OFF&gt;]</code><br /><code></code></p>
<ul>
<ul>
<ul>"pattern_for_ON" and "pattern_for_OFF" must be formed using the following structure:</ul>
</ul>
</ul>
<p><br /><code>device:[regexp]</code></p>
<p style="padding-left: 120px;">The forming-rules are the same as for the notify-command.</p>
<p><br /><br /><strong>Example:</strong></p>
<p><code>define DP_Motionsensor Dayprofile Motiensensor:on</code></p>
<p><br /><br /><a name="Dayprofile_readings"></a><strong>Readings</strong></p>
<ul>
<ul>
<ul>
<li>1</li>
<li>2</li>
</ul>
</ul>
</ul>
<p><a name="Dayprofile_get"></a><strong>get</strong></p>
<ul>
<ul>
<ul>
<li>protocol - lists all events in protocol format like HH:MM[:SS]\n</li>
<li>version - version information</li>
</ul>
</ul>
</ul>
<p><br /><a name="Dayprofile_set"></a><strong>set</strong></p>
<ul>
<ul>
<ul>
<li>HHMMSS - sets an event for the given time</li>
<li>clear - clears all events</li>
<li>forceDayChange - forces a day change</li>
<li>Hex - set hex string from another source</li>
<li>update - recalculate all readings</li>
</ul>
</ul>
</ul>
<p><br /><br /><a name="TeslaPowerwall2ACattribute"></a><strong>Attribute</strong></p>
<ul>
<ul>
<li>add_dp - comma seperated list of additional dp(dayprofile) readings with diffrent resolutzion<br />e.g. 300,900,1200<br />will generate three dp readings with resolution of 300 seconds per bit, 900 s/Bit ...</li>
<li>secondsBit - seconds per bit for event storage. Default is 300 seconds / Bit means 5 Minute timeframes: 00:00, 00:05, etc...</li>
<li>add_protocol - adds a reading like "pro" with a protocol list of all events like HH:MM[:SS]\n</li>
</ul>
</ul>

=end html

=cut
