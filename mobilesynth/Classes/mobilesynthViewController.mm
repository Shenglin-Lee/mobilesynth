//
//  mobilesynthViewController.m
//  mobilesynth
//
//  Created by Allen Porter on 12/7/08.
//  Copyright thebends 2008. All rights reserved.
//

#import "mobilesynthViewController.h"
#import "AudioOutput.h"
#import "EnvelopeView.h"
#import "KeyboardView.h"
#import "ModulationView.h"
#import "OscillatorView.h"
#import "OscillatorDetailView.h"
#include "synth/controller.h"
#include "synth/envelope.h"
#include "synth/modulation.h"
#include "synth/oscillator.h"


@implementation mobilesynthViewController

@synthesize keyboardScrollView;
@synthesize keyboardImageView;
@synthesize controlScrollView;
@synthesize controlPageControl;

@synthesize oscillatorView;
@synthesize oscillatorDetailView;
@synthesize modulationView;
@synthesize envelopeView;


// Use A above Middle C as the reference frequency
static const float kNotesPerOctave = 12.0;
static const float kMiddleAFrequency = 440.0;
static const int kMiddleANote = 49;

static float GetFrequencyForNote(int note) {
  return kMiddleAFrequency * powf(2, (note - kMiddleANote) / kNotesPerOctave);
}

- (void)noteBegin:(int)note {
  @synchronized(self) {
    float freq = GetFrequencyForNote(note);
    NSLog(@"Note: %d Freq: %f", note, freq);
    osc1_->set_frequency(freq);
    osc2_->set_frequency(freq);
    envelope_->NoteOn();
  }
}

- (void)noteEnd {
  @synchronized(self) {
    envelope_->NoteOff();
  }
}


- (void)syncControls {
  @synchronized(self) {
    [oscillatorView changed:self];
    [oscillatorDetailView changed:self];
    [modulationView changed:self];
    [envelopeView changed:self];
  }
}

- (OSStatus)generateSamples:(AudioBufferList*)buffers {
  assert(controller_);
  assert(buffers->mNumberBuffers == 1);  // mono output
  AudioBuffer* outputBuffer = &buffers->mBuffers[0];
  
  // Lazily create a data buffer to hold the generated sound data.  The
  // generated and output data are in different formats, and the audio converter
  // does the work for us.
  int samples = outputBuffer->mDataByteSize / sizeof(AudioUnitSampleType);
  if (conversionBuffer.mData == NULL) {
    conversionBuffer.mDataByteSize = samples * sizeof(float);
    conversionBuffer.mData = malloc(conversionBuffer.mDataByteSize);
  }
  
  // Generate linear PCM signal
  float* data = (float*)conversionBuffer.mData;
  for (int i = 0; i < samples; i++) {
    data[i] = controller_->GetSample();
  }
  
  // Convert the PCM data from floating point to signed integer, the preferred
  // output format.
  UInt32 outputSize = outputBuffer->mDataByteSize;
  OSStatus status = AudioConverterConvertBuffer(audioConverter,
                              conversionBuffer.mDataByteSize,
                              conversionBuffer.mData,
                              &outputSize,
                              outputBuffer->mData);
  if (status) {
    NSLog(@"AudioConverterConvertBuffer %@",
          [[NSError errorWithDomain:NSOSStatusErrorDomain
                               code:status
                           userInfo:nil] localizedDescription]);
    return status;
  }
  assert(outputSize == outputBuffer->mDataByteSize);
  return noErr;
}

// Setup the scrolable control panel
- (void)loadControlViews {
  CGRect frame = [keyboardScrollView frame];
  frame.origin.x = frame.size.width / 2;
  frame.origin.y = 0;
  frame.size.width = 10;
  frame.size.height = 10;
  [keyboardScrollView scrollRectToVisible:frame animated:YES];
  
  NSMutableArray *controlViews = [[NSMutableArray alloc] init]; 
  
  // New controls panels should be added here
  [controlViews addObject:oscillatorView];
  [controlViews addObject:oscillatorDetailView];
  [controlViews addObject:modulationView];
  [controlViews addObject:envelopeView];
  
  for (int i = 0; i < [controlViews count]; ++i) {
    UIView* view = [controlViews objectAtIndex:i];
    CGRect frame = controlScrollView.frame;
    frame.origin.x = frame.size.width * i;
    frame.origin.y = 0;
    view.frame = frame;
    [controlScrollView addSubview:view];
  }
  [controlViews release];
  
  int subviews = [[controlScrollView subviews] count];
  CGSize frameSize = [controlScrollView frame].size;
  [controlScrollView setContentSize:CGSizeMake(frameSize.width * subviews,
                                               frameSize.height)];
  [controlPageControl setNumberOfPages:subviews];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [self loadControlViews];

  // Setup the inner size of the scroll view to the size of the full keyboard
  // image.  This basically makes the scroll view work.
  [keyboardScrollView setContentSize:[[keyboardImageView image] size]];
  // TODO(allen): Start at the middle of the keyboard (Scroll to key?)
  // TODO(allen): Set this to disable scrolling, and enable sliding.
  [keyboardScrollView setScrollEnabled:NO];
  
  osc1_ = new synth::Oscillator;
  osc2_ = new synth::Oscillator;
  
  lfo_osc_ = new synth::Oscillator;
  lfo_ = new synth::LFO;
  lfo_->set_oscillator(lfo_osc_);
  
  envelope_ = new synth::Envelope;
  
  // Tie all of the components together with the controller. 
  controller_ = new synth::Controller;
  controller_->add_oscillator(osc1_);
  controller_->add_oscillator(osc2_);
  controller_->set_volume_envelope(envelope_);
  controller_->set_lfo(lfo_);  
  
  // Link the synth objects to their UI controllers
  [oscillatorView setOsc1:osc1_];
  [oscillatorView setOsc2:osc2_];
  [oscillatorDetailView setOsc2:osc2_];
  [modulationView setOsc:lfo_osc_];
  [modulationView setLfo:lfo_];
  [envelopeView setEnvelope:envelope_];
  
  [self syncControls];
  

  // Initalize all the glue
  [keyboardImageView setKeyboardDelegate:self];
  
  // Format generated by the syntheizer (floating point)
  generatedFormat.mSampleRate = 44100.0;
  generatedFormat.mFormatID = kAudioFormatLinearPCM;
  generatedFormat.mFormatFlags = kAudioFormatFlagIsFloat;
  generatedFormat.mBytesPerPacket = sizeof(Float32);
  generatedFormat.mFramesPerPacket = 1;
  generatedFormat.mBytesPerFrame = sizeof(Float32);
  generatedFormat.mChannelsPerFrame = 1;
  generatedFormat.mBitsPerChannel = 8 * sizeof(Float32);
  generatedFormat.mReserved = 0; 
  
  // Format preferred by the iphone
  outputFormat.mSampleRate = 44100.0;
  outputFormat.mFormatID = kAudioFormatLinearPCM;
  outputFormat.mFormatFlags  = kAudioFormatFlagsAudioUnitCanonical;
  outputFormat.mBytesPerPacket = sizeof(AudioUnitSampleType);
  outputFormat.mFramesPerPacket = 1;
  outputFormat.mBytesPerFrame = sizeof(AudioUnitSampleType);
  outputFormat.mChannelsPerFrame = 1;
  outputFormat.mBitsPerChannel = 8 * sizeof(AudioUnitSampleType);
  outputFormat.mReserved = 0;
  
  conversionBuffer.mData = NULL;
  conversionBuffer.mDataByteSize = 0;
  OSStatus status = AudioConverterNew(&generatedFormat, &outputFormat,
                                     &audioConverter);
  if (status) {
    [AudioOutput displayErrorAndExit:@"AudioConverterNew"
                           errorCode:status];
  }
  
  output = [[AudioOutput alloc] initWithAudioFormat:&outputFormat];
  [output setSampleDelegate:self];
  [output start];  // immediately invokes our callback to generate samples
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
  return (interfaceOrientation == UIInterfaceOrientationLandscapeRight);
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning]; // Releases the view if it doesn't have a superview
  // Release anything that's not essential, such as cached data
}

- (void)dealloc {
  [output dealloc];
  OSStatus status = AudioConverterDispose(audioConverter);
  if (status) {
    [AudioOutput displayErrorAndExit:@"AudioConverterDispose"
                           errorCode:status];
  }
  delete controller_;
  delete envelope_;
  delete lfo_osc_;
  delete lfo_;
  delete osc1_;
  delete osc2_;
  free(conversionBuffer.mData);
  [super dealloc];
}

- (void)syncPageControl {
  // Switch the indicator when more than 50% of the previous/next page is visible
  CGFloat pageWidth = controlScrollView.frame.size.width;
  int page = floor((controlScrollView.contentOffset.x - pageWidth / 2) / pageWidth) + 1;
  [controlPageControl setCurrentPage:page];
}

- (void)scrollViewDidScroll:(UIScrollView *)sender {
  // We don't want a "feedback loop" between the UIPageControl and the scroll delegate in
  // which a scroll event generated from the user hitting the page control triggers updates from
  // the delegate method. We use a boolean to disable the delegate logic when the page control is used.
  if (pageControlUsed) {
    // do nothing - the scroll was initiated from the page control, not the user dragging
    return;
  }
  [self syncPageControl];
}

// At the end of scroll animation, reset the boolean used when scrolls originate from the UIPageControl
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
  pageControlUsed = NO;
  [self syncPageControl];
}

- (IBAction)changePage:(id)sender {
  int page = [controlPageControl currentPage];
  // update the scroll view to the appropriate page
  CGRect frame = controlScrollView.frame;
  frame.origin.x = frame.size.width * page;
  frame.origin.y = 0;

  [controlScrollView scrollRectToVisible:frame animated:YES];
  // Set when scrolls originate from the UIPageControl. See scrollViewDidScroll: above.
  pageControlUsed = YES;
}


@end
