#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// FirstRunCompile (P470): the GPU programs built before the first shot needs them - the SHDR merge's (hybridPrewarmGpu of the plain
/// Bayer block, the tuning of the settings) and the post pipeline's kept from earlier runs (ScamGL's recipes).
@interface SCAMWarmUp : NSObject
/// The merge's programs for `settings` (PostSettings.json()); progress: (done, total) of the programs; the merge's log lines.
+ (NSArray<NSString *> *)prewarmMergeWithSettings:(NSString *)settings
                                         progress:(void (^)(NSInteger done, NSInteger total))progress;
/// The kept recipes at `path` linked again; returns how many were built.
+ (NSInteger)warmProgramsAtPath:(NSString *)path progress:(void (^)(NSInteger done, NSInteger total))progress;
/// This run's programs added to the recipes at `path` (at most 400 kept); returns how many the file holds, -1 on failure.
+ (NSInteger)saveProgramsToPath:(NSString *)path;
/// How many programs this run linked.
+ (NSInteger)programCount;
/// The merge's persistent CPU thread teams (ScamRowTeam, ScamPool) made on the calling thread: their threads take its QoS. Called
/// from a user-initiated task before the background warm-up could make them (a team made there would run every later shot's
/// CPU passes at background QoS).
+ (void)prepareThreads;
@end

NS_ASSUME_NONNULL_END
