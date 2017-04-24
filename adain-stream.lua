require 'torch'
require 'unsup'
require 'nn'
require 'image'
require 'paths'
require 'lib/AdaptiveInstanceNormalization'
require 'lib/utils'
require 'io'
require 'pl'


-- Options ---------------------------------------------------------------------

cmd = torch.CmdLine()

cmd:option('-video', 'webcam',
'Whether to get the stream from the webcam or from a remote IP video stream')
cmd:option('-gpu', 0, 'Zero-indexed ID of the GPU to use; for CPU mode set -gpu = -1')

opt = cmd:parse(arg)

if opt.gpu >= 0 then
    require 'cudnn'
    require 'cunn'
end

-- Variables

-- Size of inserted style (in top left corner) in rendered style transfer
size_inset=40

-- Initialise input video stream, either from the webcam or from an IP stream
if opt.video == 'webcam' then
  require 'camera'
  camera_opt = {
    idx = '0',
    fps = '1',
    height = '180',
    width = '212',
  }
  cam = image.Camera(camera_opt)
  height = '180'
  width = '212'
else
  -- load a video and extract frame dimensions
  video = require('libvideo_decoder')
  status, height, width, length, fps = video.init("http://192.168.1.20:8080/video", "mjpeg")
  if not status then
    error("No video")
  else
    print('Video statistics: '..height..'x'..width..' ('..(fps or 'unknown')..' fps)')
  end

end

-- tensor for content image
contentImg = torch.FloatTensor(3, height, width)

vgg = torch.load('models/vgg_normalised.t7')
for i = 53, 32, - 1 do
  vgg:remove(i)
end

adain = nn.AdaptiveInstanceNormalization(vgg:get(#vgg - 1).nOutputPlane)
decoder = torch.load('models/decoder.t7')

if opt.gpu >= 0 then
    cutorch.setDevice(opt.gpu+1)
    vgg = cudnn.convert(vgg, cudnn):cuda()
    adain:cuda()
    decoder:cuda()
else
    vgg:float()
    adain:float()
    decoder:float()
end

-- Style image is by default the latest added to input/syle folder
f = io.popen("ls -t input/style")
style_name = f:read()
style = image.load('input/style/'..style_name, 3, 'float')
style_inset = sizePreprocess(style, 'false', size_inset)
style = sizePreprocess(style, 'false', '200')

if opt.gpu >= 0 then
    style = style:cuda()
    style_inset = style_inset:cuda()
else
    style = style:float()
    style_inset = style_inset:float()
end

last_style_name = style_name

styleFeature = vgg:forward(style):clone()

-- Frame counter, to get an idea of frame throughput
cpt_frame = 0

freq_update_style = 60

-- timer_clock1 : Timer for checking whether a new style was uploaded (every 5s)
timer_clock1_start = math.floor(os.clock(), 0)
-- timer_clock2 : Timer for automatically changing style (every 20s)
timer_clock2_start = math.floor(os.clock(), 0)

-- Streaming loop
while true do
  -- Get elapsed time since starting the application
  timer = math.floor(os.clock(), 0)
  print(timer)

  cpt_frame = cpt_frame + 1

  -- If 5 seconds have passed, check whether a new style was uploaded
  if timer > timer_clock1_start + 5
  then
    timer_clock1_start = timer

    print('Nb frames/s : '..cpt_frame)
    cpt_frame = 0
    f = io.popen("ls -t input/style")
    last_file = f:read()
    -- If new style
    if last_style_name ~= last_file
    then
      -- Modify second timer so that new style is displayed for one minute
      timer_clock2_start = timer + 40
      last_style_name = last_file
      style = image.load('input/style/'..last_file, 3, 'float')
      style_inset = sizePreprocess(style, 'false', size_inset)
      style = sizePreprocess(style, 'true', '200')

      if opt.gpu >= 0 then
          style = style:cuda()
          style_inset = style_inset:cuda()
      else
          style = style:float()
          style_inset = style_inset:float()
      end

      styleFeature = vgg:forward(style):clone()
    end
  end

  -- If 20 have passed since last style change, choose a random new style
  if timer > timer_clock2_start + 20
  then
    timer_clock2_start = timer
    f = io.popen("ls input/style |shuf -n 1")
    new_style_name = f:read()
    style = image.load('input/style/'..new_style_name, 3, 'float')
    style_inset = sizePreprocess(style, 'true', size_inset)
    style = sizePreprocess(style, 'false', '200')

    if opt.gpu >= 0 then
        style = style:cuda()
        style_inset = style_inset:cuda()
    else
        style = style:float()
        style_inset = style_inset:float()
    end

    styleFeature = vgg:forward(style):clone()
  end

  if opt.video == 'webcam' then
    contentImg = cam:forward()
    dimW = contentImg:size()[3]
    contentImg = contentImg:index(3, torch.linspace(dimW, 1, dimW):long())
  else
    video.frame_rgb(contentImg)
  end

  -- contentImg = sizePreprocess(contentImg, 'false', '200')
  content = contentImg

  if opt.gpu >= 0 then
      content = content:cuda()
  else
      content = content:float()
  end

  contentFeature = vgg:forward(content):clone()
  targetFeature = adain:forward({contentFeature, styleFeature})

  targetFeature = targetFeature:squeeze()
  -- targetFeature = 0.5 * targetFeature + (1 - 0.5) * contentFeature
  output = decoder:forward(targetFeature)

  -- output = sizePreprocess(output, 'false', '200')

  -- Insert style image in the top left corner
  output:sub(1, 3, 1, size_inset, 1, size_inset):copy(style_inset)

  -- Display image
  imgs_out = {}
  table.insert(imgs_out, output)

  img_disp = image.toDisplayTensor{
    input = imgs_out,
    min = 0,
    max = 1,
    nrow = math.floor(math.sqrt(#imgs_out)),
  }

  if not win then
    -- On the first call use image.display to construct a window
    win = image.display(img_disp)
  else
    -- Reuse the same window
    win.image = output
    size = win.window.size:totable()
    qt_img = qt.QImage.fromTensor(img_disp)
    win.painter:image(0, 0, size.width, size.height, qt_img)
  end
end
