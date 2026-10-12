const puppeteer = require('/Users/arunthomas/.gemini/antigravity-ide/scratch/OmniSearch/node_modules/puppeteer-core');
const path = require('path');

async function captureClipLocalAssets() {
    const browser = await puppeteer.launch({
        executablePath: '/Users/arunthomas/.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.42/chrome-headless-shell-mac-arm64/chrome-headless-shell',
        headless: "new",
        args: ['--no-sandbox', '--disable-setuid-sandbox']
    });

    const page = await browser.newPage();
    await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });

    const fileUrl = 'file://' + path.resolve(__dirname, '../composition/index.html');
    await page.goto(fileUrl, { waitUntil: 'networkidle0' });

    // 1. Capture brag.jpg poster at t=5.0s (Scene 2 settled)
    await page.evaluate(() => { if (typeof seekTo === 'function') seekTo(5.0); });
    await new Promise(r => setTimeout(r, 500));
    const stage = await page.$('.stage-wrapper');
    await (stage || page).screenshot({
        path: path.resolve(__dirname, '../brag.jpg'),
        type: 'jpeg',
        quality: 92
    });
    console.log("Captured ClipLocal brag.jpg poster");

    // 2. Capture all 5 scene stills
    const keyframes = [
        { name: 'scene_01_risk.jpg', time: 1.5 },
        { name: 'scene_02_reveal.jpg', time: 5.0 },
        { name: 'scene_03_engine.jpg', time: 10.0 },
        { name: 'scene_04_free.jpg', time: 14.5 },
        { name: 'scene_05_install.jpg', time: 18.5 }
    ];

    for (const kf of keyframes) {
        await page.evaluate((t) => { if (typeof seekTo === 'function') seekTo(t); }, kf.time);
        await new Promise(r => setTimeout(r, 400));
        await (stage || page).screenshot({
            path: path.resolve(__dirname, kf.name),
            type: 'jpeg',
            quality: 92
        });
        console.log(`Saved ${kf.name}`);
    }

    await browser.close();
}

captureClipLocalAssets().catch(err => {
    console.error("Capture error:", err);
    process.exit(1);
});
