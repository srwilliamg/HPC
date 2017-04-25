#include <stdio.h>
#include <time.h>
#include <cuda.h>
#include <opencv2/highgui/highgui.hpp>
#include <opencv2/core/core.hpp>
#include <opencv2/imgproc/imgproc.hpp> // import no include errors 
#include <fstream>
#include <string>

#define RED 2
#define GREEN 1
#define BLUE 0

using namespace cv;
using namespace std;

#define MASK_WIDTH 3
#define TILE_SIZE 32

__device__ unsigned char clamp(int value){
    if(value < 0)
        value = 0;
    else
        if(value > 255)
            value = 255;
    return (unsigned char)value;
}

__global__ void sobelFilterSM(unsigned char *imageInput, int width, int height, unsigned int maskWidth, float * d_Mask, unsigned char *imageOutput){
    __shared__ float N_ds[TILE_SIZE + MASK_WIDTH - 1][TILE_SIZE+ MASK_WIDTH - 1];

    int n = maskWidth/2, dest = threadIdx.y*TILE_SIZE+threadIdx.x, destY = dest / (TILE_SIZE+MASK_WIDTH-1), destX = dest % (TILE_SIZE+MASK_WIDTH-1);
    int srcY = blockIdx.y * TILE_SIZE + destY - n, srcX = blockIdx.x * TILE_SIZE + destX - n, src = (srcY * width + srcX);

    if (srcY >= 0 && srcY < height && srcX >= 0 && srcX < width){N_ds[destY][destX] = imageInput[src];}
    else{N_ds[destY][destX] = 0;}

    dest = threadIdx.y * TILE_SIZE + threadIdx.x + TILE_SIZE * TILE_SIZE;
    destY = dest /(TILE_SIZE + MASK_WIDTH - 1), destX = dest % (TILE_SIZE + MASK_WIDTH - 1);

    srcY = blockIdx.y * TILE_SIZE + destY - n;
    srcX = blockIdx.x * TILE_SIZE + destX - n;
    src = (srcY * width + srcX);

    if (destY < TILE_SIZE + MASK_WIDTH - 1) {
        if (srcY >= 0 && srcY < height && srcX >= 0 && srcX < width)
            N_ds[destY][destX] = imageInput[src];
        else
            N_ds[destY][destX] = 0;
    }
    __syncthreads();

    int accum = 0, y, x;
    for (y = 0; y < maskWidth; y++)
        for (x = 0; x < maskWidth; x++)
            accum += N_ds[threadIdx.y + y][threadIdx.x + x] * d_Mask[y * maskWidth + x];
    y = blockIdx.y * TILE_SIZE + threadIdx.y;
    x = blockIdx.x * TILE_SIZE + threadIdx.x;
    
    if (y < height && x < width)
        imageOutput[(y * width + x)] = clamp(accum);
    __syncthreads();
}

__global__ void img2gray(unsigned char *imageInput, int width, int height, unsigned char *imageOutput){
    int row = blockIdx.y*blockDim.y+threadIdx.y;
    int col = blockIdx.x*blockDim.x+threadIdx.x;

    if((row < height) && (col < width)){
        imageOutput[row*width+col] = imageInput[(row*width+col)*3+RED]*0.299 + imageInput[(row*width+col)*3+GREEN]*0.587 
        + imageInput[(row*width+col)*3+BLUE]*0.114;
    }
}


int main(int argc, char **argv){
    cudaError_t error = cudaSuccess;
    clock_t start, end;
    int times = 1;
    double cpu_time_used;
    float h_Mask[] = {-1, 0, 1, -2, 0, 2, -1, 0, 1};
    unsigned char *h_dataImage, *d_dataImage, *d_imageOutput, *h_imageOutput, *d_sobelOutput;
    float* d_Mask;
    cudaEvent_t startGPU, stopGPU;
    cudaEventCreate(&startGPU);
    cudaEventCreate(&stopGPU);
    int maskWidth = MASK_WIDTH;

    if(argc !=3){
        printf("Enter the image's name and to repeat \n");
        return -1;
    }

    char* imageName = argv[1];
    times = atoi(argv[2]);

    Mat image;
    image = imread(imageName, 1);

    if(!image.data){return -1;}

    Size s = image.size();

    int width = s.width;
    int height = s.height;
    int size = sizeof(unsigned char)*width*height*image.channels();
    int sizeGray = sizeof(unsigned char)*width*height;

    string text  = string(imageName)+"Times";

    for (int i = 0; i < times; i++)
    {
        h_dataImage = (unsigned char*)malloc(size);
        error = cudaMalloc((void**)&d_dataImage, size);
        if(error != cudaSuccess){printf("Error-> memory allocation of d_dataImage\n");exit(-1);}

        h_imageOutput = (unsigned char *)malloc(sizeGray);
        error = cudaMalloc((void**)&d_imageOutput, sizeGray);
        if(error != cudaSuccess){printf("Error-> memory allocation of d_imageOutput\n");exit(-1);}

        error = cudaMalloc((void**)&d_Mask, sizeof(float)*MASK_WIDTH);
        if(error != cudaSuccess){printf("Error-> h_Mask to d_Mask\n");exit(-1);}

        error = cudaMalloc((void**)&d_sobelOutput, sizeGray);
        if(error != cudaSuccess){printf("Error-> memory allocation of d_sobelOutput\n");exit(-1);}

        h_dataImage = image.data;

        error = cudaMemcpy(d_dataImage, h_dataImage, size, cudaMemcpyHostToDevice);
        if(error != cudaSuccess){printf("Error sending data from host to device in dataImage\n");exit(-1);}

        error = cudaMemcpy(d_Mask, h_Mask, sizeof(float)*MASK_WIDTH, cudaMemcpyHostToDevice);
        if(error != cudaSuccess){printf("Error sending data from host to device in dataImage\n");exit(-1);}


        int blockSize = 32;
        dim3 dimBlock(blockSize, blockSize, 1);
        dim3 dimGrid(ceil(width/float(blockSize)), ceil(height/float(blockSize)), 1);
        img2gray<<<dimGrid, dimBlock>>>(d_dataImage, width, height, d_imageOutput);
        cudaDeviceSynchronize();

        cudaEventRecord(startGPU);
        sobelFilter<<<dimGrid, dimBlock>>>(d_imageOutput, width, height, maskWidth, d_Mask, d_sobelOutput);
        cudaDeviceSynchronize();
        cudaEventRecord(stopGPU);

        error = cudaMemcpy(h_imageOutput, d_sobelOutput, sizeGray, cudaMemcpyDeviceToHost);
        if(error != cudaSuccess){printf("Error sending data from device to host in imageOutput\n");exit(-1);}
        cudaEventSynchronize(stopGPU);
        float milliseconds = 0;
        cudaEventElapsedTime(&milliseconds, startGPU, stopGPU);

        Mat gray_image;
        gray_image.create(height, width, CV_8UC1);
        gray_image.data = h_imageOutput;

        start = clock();
        Mat gray_image_opencv, grad_x, abs_grad_x;
        cvtColor(image, gray_image_opencv, CV_BGR2GRAY);
        Sobel(gray_image_opencv, grad_x, CV_8UC1, 1, 0, 3, 1, 0, BORDER_DEFAULT);
        convertScaleAbs(grad_x, abs_grad_x);
        end = clock();


        //imwrite("./sobel.jpg", gray_image);

        namedWindow(imageName, WINDOW_NORMAL);
        namedWindow("Gray Image CUDA", WINDOW_NORMAL);
        //namedWindow("Sobel Image OpenCV", WINDOW_NORMAL);

        imshow(imageName, image);
        imshow("Gray Image CUDA", gray_image);
        //imshow("Sobel Image OpenCV", abs_grad_x);

        waitKey(0);

        //free(h_dataImage);
        //free(h_imageOutput);
        cpu_time_used = ((double) (end - start)) /CLOCKS_PER_SEC;
        printf("Time in CPU: %.10f, time in GPU: %.10f\n", cpu_time_used, milliseconds);

        ofstream outfile(text.c_str(),ios::binary | ios::app);
        outfile << cpu_time_used <<" "<< milliseconds << "\n";
        outfile.close();

        cudaFree(d_dataImage);
        cudaFree(d_Mask);
        cudaFree(d_imageOutput);
        cudaFree(d_sobelOutput);
    }
    return 0;
}
