Hello this is README file which we will change so that it will have all the information related to the project in detail
so a rough idea is somewhat like this
we have a systolic array which is a master at doing matrix multiplication
but in a CNN, the operation which dominates is convolution so what we are going to do is convert that operation into
simple matrix multiplication and there are multiple ways to do it but we choose the im2col protocol which basically 
flattens the data which we are interested and the corresponding kernel to that is also flattened and sent to the systolic array
that way, we get one output of the convolution so you repeat this process multiple times and you end up with getting the whole 
convolution of the image or activation with the kernel.
After that we have to do the post processing like ReLu function, softmax or any other activation then reduce the size back to 8 bit
which is the input data size and store them in the memory. To do these post processing operations, we will be using a SIMD
single instruction multiple data (that is the idea for now).

Later we will be putting the architecture and other related information with diagrams to explain all of the above in a better and 
easy to ready and understand format.

Till then this README will be left to be like this, signing off <3
