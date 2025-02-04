import 'dart:async';

import 'package:after_layout/after_layout.dart';
import 'package:better_player/better_player.dart';
import 'package:fbroadcast/fbroadcast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:logging/logging.dart';

import '../../database.dart';
import '../../globals.dart';
import '../../main.dart';
import '../../models/db/progress.dart';
import '../../models/pair.dart';
import '../../models/sponsorSegment.dart';
import '../../models/video.dart';
import '../components/videoThumbnail.dart';

class VideoPlayer extends StatefulWidget {
  final Video video;
  Function(BetterPlayerEvent event)? listener;

  VideoPlayer({super.key, required this.video, this.listener});

  @override
  State<VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayer> with AfterLayoutMixin<VideoPlayer>, RouteAware {
  final log = Logger('VideoPlayer');
  final GlobalKey _betterPlayerKey = GlobalKey();
  bool useSponsorBlock = db.getSettings(USE_SPONSORBLOCK)?.value == 'true';
  List<Pair<int>> sponsorSegments = List.of([]);
  Pair<int> nextSegment = Pair(0, 0);
  BetterPlayerController? videoController;
  int previousSponsorCheck = 0;

  @override
  void initState() {
    super.initState();
    FBroadcast.instance().register(BROAD_CAST_STOP_PLAYING, (value, callback) {
      disposeControllers();
    });
  }

  @override
  void didPopNext() {
    super.didPopNext();
    if (videoController != null) {
      log.info('popnext ${videoController?.isPlaying()}');
      if (!(videoController?.isPlaying() ?? false)) {
        // we restart the video
        disposeControllers();
      }
    }
  }

  @override
  void didPop() {
    super.didPop();
    log.info('pop');
  }

  @override
  void didPush() {
    super.didPush();
    log.info('push');
  }

  @override
  void didPushNext() {
    super.didPushNext();
    log.info('push next');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context) as PageRoute<dynamic>);
  }

  @override
  void dispose() {
    disposeControllers();
    super.dispose();
  }

  @override
  didUpdateWidget(VideoPlayer old) {
    super.didUpdateWidget(old);
    if (old.video.videoId != widget.video.videoId) {
      disposeControllers();
      playVideo();
    }
  }

  disposeControllers() {
    if (videoController != null) {
      videoController!.removeEventsListener(onVideoListener);
      videoController!.dispose();
      if (context.mounted) {
        setState(() {
          videoController = null;
        });
      }
    }
  }

  saveProgress(int timeInSeconds) {
    if (videoController != null) {
      int currentPosition = timeInSeconds;
      // saving progress
      int max = widget.video.lengthSeconds ?? 0;
      var progress = Progress.named(progress: currentPosition / max, videoId: widget.video.videoId);
      db.saveProgress(progress);
    }
  }

  onVideoListener(BetterPlayerEvent event) {
    if (event.betterPlayerEventType == BetterPlayerEventType.progress) {
      int currentPosition = (event.parameters?['progress'] as Duration).inSeconds;
      if (currentPosition > previousSponsorCheck + 1) {
        // saving progress
        saveProgress(currentPosition);
        log.info("video event");

        if (useSponsorBlock && sponsorSegments.isNotEmpty) {
          double positionInMs = currentPosition * 1000;
          Pair<int> nextSegment = sponsorSegments.firstWhere((e) => e.first <= positionInMs && positionInMs <= e.last, orElse: () => Pair<int>(-1, -1));
          if (nextSegment.first != -1) {
            var locals = AppLocalizations.of(context)!;
            videoController!.seekTo(Duration(milliseconds: nextSegment.last + 1000));
            final ScaffoldMessengerState? scaffold = scaffoldKey.currentState;
            scaffold?.showSnackBar(SnackBar(
              content: Text(locals.sponsorSkipped),
              duration: const Duration(seconds: 1),
            ));
          }
        }

        if (widget.listener != null) {
          widget.listener!(event);
        }

        previousSponsorCheck = currentPosition;

        if (widget.listener != null) {
          widget.listener!(event);
        }
      } else if (currentPosition + 2 < previousSponsorCheck) {
        // if we're more than 2 seconds behind, means we probably seek backward manually far away
        // so we reset the position
        previousSponsorCheck = currentPosition;
      }
    } else if (event.betterPlayerEventType == BetterPlayerEventType.finished) {
      if (widget.listener != null) {
        widget.listener!(event);
      }
    }
  }

  playVideo() {
    double progress = db.getVideoProgress(widget.video.videoId);
    Duration? startAt;
    if (progress > 0 && progress < 0.90) {
      startAt = Duration(seconds: (widget.video.lengthSeconds * progress).floor());
    }

    String baseUrl = db.getCurrentlySelectedServer().url;

    Map<String, String> resolutions = {};

    for (var value in widget.video.formatStreams) {
      resolutions[value.qualityLabel] = value.url;
    }

    BetterPlayerDataSource betterPlayerDataSource =
        BetterPlayerDataSource(BetterPlayerDataSourceType.network, widget.video.hlsUrl ?? widget.video.formatStreams[widget.video.formatStreams.length - 1].url,
            videoFormat: widget.video.hlsUrl != null ? BetterPlayerVideoFormat.hls : BetterPlayerVideoFormat.other,
            liveStream: widget.video.liveNow,
            subtitles: widget.video.captions.map((s) => BetterPlayerSubtitlesSource(type: BetterPlayerSubtitlesSourceType.network, urls: ['${baseUrl}${s.url}'], name: s.label)).toList(),
            resolutions: resolutions,
            // placeholder: VideoThumbnailView(videoId: widget.video.videoId, thumbnailUrl: widget.video.getBestThumbnail()?.url ?? ''),
            notificationConfiguration: BetterPlayerNotificationConfiguration(
              showNotification: true,
              activityName: 'MainActivity',
              title: widget.video.title,
              author: widget.video.author,
              imageUrl: widget.video.getBestThumbnail()?.url ?? '',
            ));

    setState(() {
      videoController = BetterPlayerController(BetterPlayerConfiguration(handleLifecycle: false, startAt: startAt, autoPlay: true, allowedScreenSleep: false, fit: BoxFit.contain),
          betterPlayerDataSource: betterPlayerDataSource);
      videoController!.addEventsListener(onVideoListener);
      videoController!.isPictureInPictureSupported().then((supported) {
        if (supported) {
          videoController!.enablePictureInPicture(_betterPlayerKey);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    return AspectRatio(
        aspectRatio: 16 / 9,
        child: AnimatedSwitcher(
            duration: animationDuration,
            child: videoController != null
                ? BetterPlayer(key: _betterPlayerKey, controller: videoController!)
                : VideoThumbnailView(
                    videoId: widget.video.videoId,
                    thumbnailUrl: widget.video.getBestThumbnail()?.url ?? '',
                    child: IconButton(
                      key: const ValueKey('nt-playing'),
                      onPressed: () => playVideo(),
                      icon: const Icon(
                        Icons.play_arrow,
                        size: 100,
                      ),
                      color: colorScheme.primary,
                    ),
                  )));
  }

  setSponsorBlock(BuildContext context) async {
    if (useSponsorBlock) {
      List<SponsorSegment> sponsorSegments = await service.getSponsorSegments(widget.video.videoId);
      List<Pair<int>> segments = List.from(sponsorSegments.map((e) {
        Duration start = Duration(seconds: e.segment[0].floor());
        Duration end = Duration(seconds: e.segment[1].floor());
        Pair<int> segment = Pair(start.inMilliseconds, end.inMilliseconds);
        return segment;
      }).toList());

      if (context.mounted) {
        setState(() {
          this.sponsorSegments = segments;
        });
      }
    }
  }

  @override
  Future<FutureOr<void>> afterFirstLayout(BuildContext context) async {
    setSponsorBlock(context);
  }
}
